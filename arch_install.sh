set -euo pipefail
#!/bin/bash
IFS=$'\n\t'

read_input() {
  local prompt=$1
  local mode=$2
  local target_var=$3
  local answer=""
  local answer_confirmation=""
  local try_again=true
  while [ "$try_again" = true ]
  do
    try_again=false
    read -rs -p "$prompt" answer
    printf "\n">&2
    if [ "$mode" == "password" ]
      then
        read -rs -p "Please re-type your password:" answer_confirmation
        printf "\n">&2
        if [ "$answer" != "$answer_confirmation" ]
        then
          try_again=true
          printf "First and second attempt to type password do not match. Please try again.\n">&2
        fi
    fi
  done
  printf -v "$target_var" "%s" "$answer"
}

prepare_environment() {
  loadkeys us
  setfont eurlatgr
  timedatectl set-timezone America/Chicago
  timedatectl set-ntp true
  # Enable 32-bit repos for Steam
  sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
  sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
}

drive_partitioning() {
  local luks_password=$1
  local disk
  local number_partitions
  local efi_partition
  local boot_partition
  local root_partition

  disk=$(lsblk -dno NAME | grep -v loop | head -n 1 | awk '{print "/dev/" $1}')
  number_partitions=$(lsblk | grep -c part || true)

  # Create a temporary directory for our partition definitions
  mkdir -p /tmp/repart.d

  # Define the BOOT partition (Standard systemd XBOOTLDR partition)
  cat << 'EOF' > /tmp/repart.d/20-boot.conf
[Partition]
Type=xbootldr
Label=BOOT
SizeMinBytes=1G
SizeMaxBytes=1G
EOF

  # Define the ROOT partition (Takes up the rest of the disk)
  cat << 'EOF' > /tmp/repart.d/30-root.conf
[Partition]
Type=root-x86-64
Label=ROOT
# Omitting SizeMinBytes/SizeMaxBytes tells it to use all remaining unallocated space
EOF

  # Handle Single vs Dual Boot Execution
  if [ "$number_partitions" == "0" ]; then
    # Blank disk: Define the EFI partition
    cat << 'EOF' > /tmp/repart.d/10-efi.conf
[Partition]
Type=esp
Label=EFI
SizeMinBytes=1G
SizeMaxBytes=1G
EOF
    
    # Wipe the disk and create the new GPT table and partitions
    systemd-repart --empty=force --definitions=/tmp/repart.d --dry-run=no "$disk"

    # MUST WAIT for the kernel to recognize the new partitions
    udevadm settle

    # Identify and format the EFI partition
    efi_partition=$(blkid | grep EFI | awk -F ':' '{print $1}')
    mkfs.fat -F 32 "$efi_partition"
  else
    # Dual boot: Just append the BOOT and ROOT partitions to the unallocated space
    systemd-repart --definitions=/tmp/repart.d --dry-run=no "$disk"
    
    # MUST WAIT for the kernel to recognize the new partitions
    udevadm settle

    # Identify existing EFI partition
    efi_partition=$(blkid | grep EFI | awk -F ':' '{print $1}')
  fi

  udevadm settle
  
  # Identify our newly created partitions
  boot_partition=$(blkid | grep BOOT | awk -F ':' '{print $1}')
  root_partition=$(blkid | grep ROOT | awk -F ':' '{print $1}')

  # Encrypt the root partition
  echo -n "$luks_password" | cryptsetup luksFormat "$root_partition" -q --type luks2 --batch-mode
  
  # Unlock the root partition
  echo -n "$luks_password" | cryptsetup open "$root_partition" cryptroot --key-file=-
  
  # Format the root partition
  mkfs.btrfs -L archlinux /dev/mapper/cryptroot
  mount /dev/mapper/cryptroot /mnt
  
  # Format and explicitly mount the boot partition as vfat
  mkfs.fat -F 32 "$boot_partition"
  mount -t vfat -o umask=0077 --mkdir "$boot_partition" /mnt/boot
  
  # Explicitly mount EFI partition as vfat
  mount -t vfat -o umask=0077 --mkdir "$efi_partition" /mnt/efi
  
  # Install the base system
  pacstrap -K /mnt base linux linux-firmware
  
  # Clean up temporary definitions
  rm -rf /tmp/repart.d
}

write_pacman_hooks() {
  mkdir -p /mnt/etc/pacman.d/hooks
  cat << 'EOF' > /mnt/etc/pacman.d/hooks/90-kernel-install.hook
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Installing kernel and generating UKI...
When = PostTransaction
Exec = /bin/sh -c 'for f in /usr/lib/modules/*/vmlinuz; do kver=$(basename $(dirname "$f")); kernel-install add "$kver" "$f"; done'
NeedsTargets
EOF
  cat << EOF > /mnt/etc/pacman.d/hooks/95-systemd-boot.hook
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
EOF
  cat << 'EOF' > /mnt/etc/pacman.d/hooks/80-secureboot.hook
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/systemd/boot/efi/systemd-boot*.efi

[Action]
Description = Signing systemd-boot EFI binary for Secure Boot
When = PostTransaction
Exec = /bin/sh -c 'while read -r f; do /usr/lib/systemd/systemd-sbsign sign --private-key /etc/kernel/secure-boot-private-key.pem --certificate /etc/kernel/secure-boot-certificate.pem --output "${f}.signed" "$f"; done;'
Depends = sh
NeedsTargets
EOF
}

write_kernel_configs() {
  uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
  mkdir -p /mnt/etc/kernel
 cat << EOF > /mnt/etc/kernel/cmdline
rd.luks.name=UUID=${uuid}=cryptroot root=/dev/mapper/cryptroot rw splash quiet
EOF
  cat << EOF > /mnt/etc/kernel/install.conf
layout=uki
uki_generator=ukify
initrd_generator=dracut
EOF
  cat << EOF > /mnt/etc/kernel/uki.conf
[UKI]
SecureBootSigningTool=systemd-sbsign
SignKernel=true
SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem
SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem
EOF
}

install_base_packages() {
  # For nvidia: nvidia-open-dkms nvidia-utils lib32-nvidia-utils linux-firmware-nvidia
  # For AMD: vulkan-radeon lib32-vulkan-radeon linux-firmware-amdgpu
  pacstrap -K /mnt base-devel git systemd-ukify vim plymouth amd-ucode pipewire-jack tesseract-data-eng noto-fonts noto-fonts-cjk noto-fonts-emoji xdg-desktop-portal-kde qt6-multimedia-ffmpeg man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl dracut zram-generator rpcbind which cups gutenprint xorg-xwayland vulkan-tools steam gamemode lib32-gamemode lutris flatpak firewalld firefox libreoffice-fresh tuned mesa lib32-mesa pipewire wireplumber networkmanager plasma-meta system-config-printer tuned-ppd konsole dolphin kate skanpage gwenview plasma-systemmonitor khelpcenter sweeper partitionmanager kolourpaint ksystemlog isoimagewriter ktorrent ark kcalc spectacle hunspell hunspell-en_us sddm
  ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
}

generate_chroot_script() {
  cat << 'CHROOT_EOF' > /mnt/root/chroot_setup.sh
#!/bin/bash
set -euo pipefail
username=$1
full_name=$2
account_password=$3
sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
plymouth-set-default-theme spinfinity
systemctl enable fstrim.timer
systemctl enable systemd-oomd
systemctl enable tuned
systemctl enable tuned-ppd
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc
localectl set-keymap us
cat << EOF > /etc/vconsole.conf
KEYMAP=us
FONT=eurlatgr
EOF
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
hostnamectl hostname arch
cp /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/89-ethernet.network
systemctl enable systemd-resolved
#systemctl enable systemd-networkd
mkdir -p /etc/NetworkManager/conf.d
cat << 'EOF' > /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved
EOF
systemctl enable NetworkManager
cat << EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
#echo 'omit_drivers+=" nouveau "' > /etc/dracut.conf.d/99-nouveau.conf
sbctl create-keys
sbctl enroll-keys -m
cp /var/lib/sbctl/keys/db/db.key /etc/kernel/secure-boot-private-key.pem
cp /var/lib/sbctl/keys/db/db.pem /etc/kernel/secure-boot-certificate.pem
pacman -Rns --noconfirm sbctl
rm -rf /var/lib/sbctl
openssl x509 -in /etc/kernel/secure-boot-certificate.pem -outform DER -out /etc/kernel/secure-boot-certificate.der
mkdir -p /var/lib/dkms
ln -sf /etc/kernel/secure-boot-private-key.pem /var/lib/dkms/mok.key
ln -sf /etc/kernel/secure-boot-certificate.der /var/lib/dkms/mok.pub
uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
echo "cryptroot UUID=$uuid none discard" > /etc/crypttab
mkdir /etc/crypttab.d
device_name=$(awk '{print $1}' /etc/crypttab)
device_uuid=$(awk '{print $2}' /etc/crypttab)
cat << EOF > /etc/crypttab.d/"${device_name}".conf
NAME=$device_name
DEVICE=$device_uuid
OPTIONS=discard,tpm2-device=auto,x-initrd.attach
EOF
# Can add module.sig_enforce=1 modprobe.blacklist=nouveau if wanted
pacman -S --noconfirm systemd
bootctl install
systemctl enable systemd-homed.service
ln -s /usr/bin/vim /usr/bin/vi
echo "alias ll='ls -l' 2>/dev/null" > /etc/profile.d/ll.sh
cat << EOF > /etc/systemd/system/firstboot-homed.service
[Unit]
Description=Create initial homed user
After=systemd-homed.service
Requires=systemd-homed.service
ConditionPathExists=!/var/lib/systemd/home/$username.home

[Service]
Type=oneshot
# Use the PASSWORD environment variable to bypass the interactive TTY prompt
ExecStart=/bin/bash -c "NEWPASSWORD='${account_password}' homectl create ${username} --storage=directory --group=${username} --member-of=wheel --shell=/bin/bash --real-name='${full_name}'"
# Delete this service file so the password isn't left on disk
ExecStartPost=/usr/bin/rm /etc/systemd/system/firstboot-homed.service
ExecStartPost=/usr/bin/systemctl disable firstboot-homed.service

[Install]
WantedBy=multi-user.target
EOF
systemctl enable firstboot-homed.service
flatpak install -y com.heroicgameslauncher.hgl
# Install the right version of gamescope for Heroic Games Launcher
heroic_runtime=$(flatpak list --columns=application,runtime|grep heroic|awk -F '/' '{print $3}')
flatpak install -y flathub org.freedesktop.Platform.VulkanLayer.gamescope//"$heroic_runtime"
flatpak install -y com.discordapp.Discord/x86_64/stable
#systemctl enable plasmalogin
mkdir -p /etc/sddm.conf.d
cat << 'EOF' > /etc/sddm.conf.d/uid.conf
[Users]
MaximumUid=65000
EOF
systemctl enable sddm
systemctl enable firewalld
firewall-offline-cmd --new-zone=ArchWorkstation
firewall-offline-cmd --zone=ArchWorkstation --set-description="Unsolicited incoming network packets are rejected..."
firewall-offline-cmd --zone=ArchWorkstation --add-service=dhcpv6-client
firewall-offline-cmd --zone=ArchWorkstation --add-port=1025-65535/udp
firewall-offline-cmd --zone=ArchWorkstation --add-port=1025-65535/tcp
firewall-offline-cmd --zone=ArchWorkstation --add-forward
firewall-offline-cmd --set-default-zone=ArchWorkstation
#rm -f /etc/firewalld/firewalld.conf
#ln -s /etc/firewalld/firewalld-workstation.conf /etc/firewalld/firewalld.conf
systemctl enable cups
cat << 'EOF' > /usr/local/bin/firstboot-pcrlock.sh
#!/bin/bash
set -euo pipefail

# 1. Generate the policy based on the actual bare-metal boot
systemd-pcrlock make-policy

# 2. Find the backing physical drive using your existing logic
drive=$(lsblk | grep -B 1 crypt | head -1 | awk -F '─' '{print $2}' | awk '{print $1}')

# 3. Enroll the LUKS drive using the generated policy
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrlock=/var/lib/systemd/pcrlock.json /dev/"$drive"
EOF

chmod +x /usr/local/bin/firstboot-pcrlock.sh

# Create the transient service to run the script
cat << 'EOF' > /etc/systemd/system/firstboot-pcrlock.service
[Unit]
Description=First boot TPM policy generation and LUKS enrollment
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot-pcrlock.sh
# Clean up both the script and the service file so it never runs again
ExecStartPost=/usr/bin/rm -f /usr/local/bin/firstboot-pcrlock.sh
ExecStartPost=/usr/bin/rm -f /etc/systemd/system/firstboot-pcrlock.service
ExecStartPost=/usr/bin/systemctl disable firstboot-pcrlock.service

[Install]
WantedBy=multi-user.target
EOF

systemctl enable firstboot-pcrlock.service
bootctl install
pacman -S --noconfirm linux
CHROOT_EOF
  chmod +x /mnt/root/chroot_setup.sh
}

execute_chroot() {
  arch-chroot /mnt /bin/bash /root/chroot_setup.sh "$1" "$2" "$3"
  rm -f /mnt/root/chroot_setup.sh
}

finalize_installation() {
  umount -R /mnt
  systemctl reboot
}

new() {
  chmod +x arch_build/mkosi.postinst.chroot
  echo "$luks_password" > arch_build/root.key
  chmod 600 arch_build/root.key
  pacman -Sy sbctl mkosi cpio python-pefile systemd-ukify --noconfirm
  sbctl create-keys
  mkdir -p arch_build/mkosi.extra/var/lib/sbctl/
  cp -r /var/lib/sbctl/keys arch_build/mkosi.extra/var/lib/sbctl/keys
  sed -i "s|ACCOUNT_PASSWORD|$account_password|g" arch_build/mkosi.extra/etc/systemd/system/firstboot-homed.service
  sed -i "s|USERNAME|$username|g" arch_build/mkosi.extra/etc/systemd/system/firstboot-homed.service
  sed -i "s|FULL_NAME|$full_name|g" arch_build/mkosi.extra/etc/systemd/system/firstboot-homed.service
  BUILD_VER=$(date +%Y.%m.%d)
  # 1. Build the OS, then the system extension
  mkosi -C arch_build build --image-version="$BUILD_VER"
  mkosi -C arch_devtools build --image-version="$BUILD_VER"
  # 2. Inject the compiled extension directly into the Base OS's /var tree
  mkdir -p arch_build/mkosi.extra/var/lib/extensions/
  cp "arch_devtools/devtools.raw" "arch_build/mkosi.extra/var/lib/extensions/devtools_$BUILD_VER.raw"
  # 3. Build the Base OS
  mkosi -C arch_build build --image-version="$BUILD_VER"
  # Flash the generated image to your main drive
  #dd if="$PWD/arch_build/arch.raw" of=/dev/nvme0n1 bs=4M status=progress
}

main() {
  local luks_password
  local username
  local full_name
  local account_password
  read_input "Please provide a LUKS password:" "password" "luks_password"
  read_input "Please provide a username for your account:" "username" "username"
  read_input "Please provide your name as you wish it to be displayed:" "username" "full_name"
  read_input "Please provide a password for your account:" "password" "account_password"
  new
  #prepare_environment
  #drive_partitioning "$luks_password"
  #write_pacman_hooks
  #write_kernel_configs
  #install_base_packages
  #generate_chroot_script
  #execute_chroot "$username" "$full_name" "$account_password"
  #finalize_installation
}

main
