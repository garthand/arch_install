#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

drive_partitioning() {
  local luks_password=$1
  local disk=$(/usr/bin/lsblk|/usr/bin/grep disk|/usr/bin/awk '{print "/dev/" $1}')
  /usr/bin/loadkeys us
  /usr/bin/setfont eurlatgr
  /usr/bin/timedatectl set-timezone America/Chicago
  /usr/bin/timedatectl set-ntp true
  # Enable 32-bit repos for Steam
  /usr/bin/sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
  /usr/bin/sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
  # Check if the disk already has partitions or if this is a totally blank disk
  local number_partitions=$(/usr/bin/lsblk|/usr/bin/grep -c part || true)
  # If Arch will be the only OS on the system
  if [ "$number_partitions" == "0" ]
  then
    # Erase the disk
    /usr/bin/sgdisk --zap-all "$disk"
    # Create the EFI partition
    /usr/bin/sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"EFI" "$disk"
    # Create the boot partition
    /usr/bin/sgdisk -n 2:0:+1G -t 2:8300 -c 2:"BOOT" "$disk"
    # Create the root partition
    /usr/bin/sgdisk -n 3:0:0 -t 3:8304 -c 3:"ROOT" "$disk"
    # Identify and format the EFI partition
    local efi_partition=$(/usr/bin/blkid|/usr/bin/grep EFI|/usr/bin/awk -F ':' '{print $1}')
    /usr/bin/mkfs.fat -F 32 "$efi_partition"
  # If Windows is already installed and we're dual-booting
  else
    local last_partition_number=$(/usr/bin/gdisk -l "$disk"|/usr/bin/awk '{print $1}')
    local boot_partition_number=$((last_partition_number + 1))
    local root_partition_number=$((boot_partition_number + 1))
    # Create the boot partition
    /usr/bin/sgdisk -n "$boot_partition_number":0:+1G -t "$boot_partition_number":8300 -c "$boot_partition_number":"BOOT" "$disk"
    # Create the root partition
    /usr/bin/sgdisk -n "$root_partition_number":0:0 -t "$root_partition_number":8304 -c "$root_partition_number":"ROOT" "$disk"
    # Identify the EFI partition
    local efi_partition=$(/usr/bin/blkid|/usr/bin/grep EFI|/usr/bin/awk -F ':' '{print $1}')
  fi
  /usr/bin/udevadm settle
  local boot_partition=$(/usr/bin/blkid|/usr/bin/grep BOOT|/usr/bin/awk -F ':' '{print $1}')
  local root_partition=$(/usr/bin/blkid|/usr/bin/grep ROOT|/usr/bin/awk -F ':' '{print $1}')
  # Ecrypt the root partition
  /usr/bin/echo -n "$luks_password" | /usr/bin/cryptsetup luksFormat "$root_partition" -q --type luks2 --batch-mode
  # Unlock the root partition
  /usr/bin/echo -n "$luks_password" | /usr/bin/cryptsetup open "$root_partition" cryptroot --key-file=-
  # Format the root partition
  /usr/bin/mkfs.btrfs -L archlinux /dev/mapper/cryptroot
  # Mount the root partition
  /usr/bin/mount /dev/mapper/cryptroot /mnt
  # Format the boot partition
  /usr/bin/mkfs.fat -F 32 "$boot_partition"
  # Mount boot partition
  /usr/bin/mount -t vfat -o umask=0077 --mkdir "$boot_partition" /mnt/boot
  # Mount EFI partition
  /usr/bin/mount -t vfat -o umask=0077 --mkdir "$efi_partition" /mnt/boot/EFI
  # Install the base system
  /usr/bin/pacstrap -K /mnt base linux linux-firmware
  # Generate a clean fstab with the boot, EFI and root partitions
  /usr/bin/genfstab -U /mnt >> /mnt/etc/fstab
}

rest() {
# For nvidia: nvidia-open-dkms nvidia-utils lib32-nvidia-utils linux-firmware-nvidia
# For AMD: vulkan-radeon lib32-vulkan-radeon linux-firmware-amdgpu
pacstrap -K /mnt base-devel git systemd-ukify vim plymouth amd-ucode pipewire-jack tesseract-data-eng noto-fonts noto-fonts-cjk noto-fonts-emoji xdg-desktop-portal-kde qt6-multimedia-ffmpeg man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl dracut sudo zram-generator rpcbind which cups gutenprint xorg-xwayland vulkan-tools firewalld tuned mesa lib32-mesa pipewire wireplumber networkmanager plasma-meta system-config-printer tuned-ppd konsole dolphin kate skanpage gwenview plasma-systemmonitor khelpcenter sweeper partitionmanager kolourpaint ksystemlog isoimagewriter ktorrent ark kcalc spectacle hunspell hunspell-en_us 
ln -sf ../run/NetworkManager/resolv.conf /mnt/etc/resolv.conf
exit
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
#systemctl enable systemd-resolved
#systemctl enable systemd-networkd
systemctl enable NetworkManager
mkdir /etc/pacman.d/hooks
cat << EOF > /etc/pacman.d/hooks/95-systemd-boot.hook
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
EOF
cat << 'EOF' > /etc/pacman.d/hooks/80-secureboot.hook
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
mkdir /etc/crypttab.d
device_name=$(sudo awk '{print $1}' /etc/crypttab)
device_uuid=$(sudo awk '{print $2}' /etc/crypttab)
cat << EOF > /etc/crypttab.d/"${device_name}".conf
NAME=$device_name
DEVICE=$device_uuid
OPTIONS=discard,tpm2-device=auto,x-initrd.attach
EOF
uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
echo "cryptroot UUID=$uuid none discard" > /etc/crypttab
kernel_version=$(ls /usr/lib/modules)
bootctl install
dracut --kver "$kernel_version" --force /boot/initramfs-linux.img
# Can add module.sig_enforce=1 modprobe.blacklist=nouveau if wanted
ukify build --linux /boot/vmlinuz-linux --initrd /boot/initramfs-linux.img --cmdline "rd.luks.name=UUID=$uuid=cryptroot root=/dev/mapper/cryptroot rw splash quiet" --output /boot/EFI/Linux/linux-arch.efi --sign-kernel --secureboot-private-key=/etc/kernel/secure-boot-private-key.pem --secureboot-certificate=/etc/kernel/secure-boot-certificate.pem --signtool=systemd-sbsign --uname=$kernel_version
pacman -S --noconfirm systemd
bootctl install
systemctl enable systemd-homed.service
ln -s /usr/bin/vim /usr/bin/vi
echo "alias ll='ls -l' 2>/dev/null" > /etc/profile.d/ll.sh
#homectl create testuser --storage=directory --group=testuser --member-of=wheel --shell=/bin/bash --real-name="Test User" --password
useradd testuser -m -G wheel -s "/bin/bash" -c "Test User" -p $(openssl passwd -6 "password")
systemctl enable plasmalogin
systemctl enable firewalld
cat << EOF > /etc/firewalld/firewalld-workstation.conf
# firewalld config file

# default zone
# The default zone used if an empty zone string is used.
# Default: public
DefaultZone=ArchWorkstation

# Clean up on exit
# If set to no or false the firewall configuration will not get cleaned up
# on exit or stop of firewalld.
# Default: yes
CleanupOnExit=yes

# Clean up kernel modules on exit
# If set to yes or true the firewall related kernel modules will be
# unloaded on exit or stop of firewalld. This might attempt to unload
# modules not originally loaded by firewalld.
# Default: no
CleanupModulesOnExit=no

# IPv6_rpfilter
# Performs reverse path filtering (RPF) on IPv6 packets as per RFC 3704.
# Possible values:
#   - strict: Performs "strict" filtering as per RFC 3704. This check
#             verifies that the in ingress interface is the same interface
#             that would be used to send a packet reply to the source. That
#             is, ingress == egress.      
#   - loose: Performs "loose" filtering as per RFC 3704. This check only
#            verifies that there is a route back to the source through any
#            interface; even if it's not the same one on which the packet
#            arrived.
#   - strict-forward: This is almost identical to "strict", but does not perform
#                     RPF for packets targeted to the host (INPUT).
#   - loose-forward: This is almost identical to "loose", but does not perform
#                    RPF for packets targeted to the host (INPUT).
#   - no: RPF is completely disabled.
#
# The rp_filter for IPv4 is controlled using sysctl.
# Note: This feature has a performance impact. See man page FIREWALLD.CONF(5)
# for details.
# Default: strict
IPv6_rpfilter=loose

# IndividualCalls
# Do not use combined -restore calls, but individual calls. This increases the
# time that is needed to apply changes and to start the daemon, but is good for
# debugging.
# Default: no
IndividualCalls=no

# LogDenied
# Add logging rules right before reject and drop rules in the INPUT, FORWARD
# and OUTPUT chains for the default rules and also final reject and drop rules
# in zones. Possible values are: all, unicast, broadcast, multicast and off.
# Default: off
LogDenied=off

# FirewallBackend
# Selects the firewall backend implementation.
# Choices are:
#	- nftables (default)
#	- iptables (iptables, ip6tables, ebtables and ipset)
# Note: The iptables backend is deprecated. It will be removed in a future
# release.
FirewallBackend=nftables

# FlushAllOnReload
# Flush all runtime rules on a reload. In previous releases some runtime
# configuration was retained during a reload, namely; interface to zone
# assignment, and direct rules. This was confusing to users. To get the old
# behavior set this to "no".
# Default: yes
FlushAllOnReload=yes

# ReloadPolicy
# Policy during reload. By default all traffic except for established
# connections is dropped while the rules are updated. Set to "DROP", "REJECT"
# or "ACCEPT". Alternatively, specify it per table, like
# "OUTPUT:ACCEPT,INPUT:DROP,FORWARD:REJECT".
# Default: ReloadPolicy=INPUT:DROP,FORWARD:DROP,OUTPUT:DROP
ReloadPolicy=INPUT:DROP,FORWARD:DROP,OUTPUT:DROP

# RFC3964_IPv4
# As per RFC 3964, filter IPv6 traffic with 6to4 destination addresses that
# correspond to IPv4 addresses that should not be routed over the public
# internet.
# Defaults to "yes".
RFC3964_IPv4=yes

# StrictForwardPorts
# If set to yes, the generated destination NAT (DNAT) rules will NOT accept
# traffic that was DNAT'd by other entities, e.g. docker. Firewalld will be
# strict and not allow published container ports until they're explicitly
# allowed via firewalld.
# If set to no, then docker (and podman) integrates seamlessly with firewalld.
# Published container ports are implicitly allowed.
# Defaults to "no".
StrictForwardPorts=no

# NftablesFlowtable
# This may improve forwarded traffic throughput by enabling nftables flowtable.
# It is a software fastpath and avoids calling nftables rule evaluation for
# data packets. This only works for TCP and UDP traffic.
# The value is a space separated list of interfaces.
# Example value "eth0 eth1".
# Defaults to "off".
NftablesFlowtable=off

# NftablesCounters
# If set to yes, add a counter to every nftables rule. This is useful for
# debugging and comes with a small performance cost.
# Defaults to "no".
NftablesCounters=no

# NftablesTableOwner
# If set to yes, the generated nftables rule set will be owned exclusively by
# firewalld. This prevents other entities from mistakenly (or maliciously)
# modifying firewalld's rule set. If you intentionally modify firewalld's
# rules, then you will have to set this to "no".
# Defaults to "yes".
NftablesTableOwner=yes
EOF
cat << EOF > /etc/firewalld/zones/ArchWorkstation.xml
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Arch Workstation</short>
  <description>Unsolicited incoming network packets are rejected from port 1 to 1024, except for select network services. Incoming packets that are related to outgoing network connections are accepted. Outgoing network connections are allowed.</description>
  <service name="dhcpv6-client"/>
  <port port="1025-65535" protocol="udp"/>
  <port port="1025-65535" protocol="tcp"/>
  <forward/>
</zone>
EOF
rm -f /etc/firewalld/firewalld.conf
ln -s /etc/firewalld/firewalld-workstation.conf /etc/firewalld/firewalld.conf
unlink /bin/sh
ln -s dash /bin/sh
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
usermod -a -G wheel testuser
systemctl enable cups
#drive=$(lsblk|grep -B 1 crypt|head -1|awk -F '─' '{print $2}'|awk '{print $1}')
#systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/"$drive"
}

main() {
  local luks_password="$1"
  drive_partitioning "$luks_password"
  rest
}

main $1


#read_input() {
#  local prompt=$1
#  local mode=$2
#  local target_var=$3
#  local answer=""
#  local answer_confirmation=""
#  local try_again=true
#  while [ "$try_again" = true ]
#  do
#    try_again=false
#    read -rs -p "$prompt" answer
#    printf "\n">&2
#    if [ "$mode" == "password" ]
#      then
#        read -rs -p "Please re-type your password:" answer_confirmation
#        printf "\n">&2
#        if [ "$answer" != "$answer_confirmation" ]
#        then
#          try_again=true
#          printf "First and second attempt to type password do not match. Please try again.\n">&2
#        fi
#    fi
#  done
#  printf -v "$target_var" "%s" "$answer"
#}
#
#prepare_environment() {
#  loadkeys us
#  setfont eurlatgr
#  timedatectl set-timezone America/Chicago
#  timedatectl set-ntp true
#  # Enable 32-bit repos for Steam
#  sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
#  sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
#}
#
#drive_partitioning() {
#  local luks_password=$1
#  local disk
#  local number_partitions
#  local efi_partition
#  local boot_partition
#  local root_partition
#
#  disk=$(lsblk -dno NAME | grep -v loop | head -n 1 | awk '{print "/dev/" $1}')
#  number_partitions=$(lsblk | grep -c part || true)
#
#  # Create a temporary directory for our partition definitions
#  mkdir -p /tmp/repart.d
#
#  # Define the BOOT partition (Standard systemd XBOOTLDR partition)
#  cat << 'EOF' > /tmp/repart.d/20-boot.conf
#[Partition]
#Type=xbootldr
#Label=BOOT
#SizeMinBytes=1G
#SizeMaxBytes=1G
#EOF
#
#  # Define the ROOT partition (Takes up the rest of the disk)
#  cat << 'EOF' > /tmp/repart.d/30-root.conf
#[Partition]
#Type=root-x86-64
#Label=ROOT
## Omitting SizeMinBytes/SizeMaxBytes tells it to use all remaining unallocated space
#EOF
#
#  # Handle Single vs Dual Boot Execution
#  if [ "$number_partitions" == "0" ]; then
#    # Blank disk: Define the EFI partition
#    cat << 'EOF' > /tmp/repart.d/10-efi.conf
#[Partition]
#Type=esp
#Label=EFI
#SizeMinBytes=1G
#SizeMaxBytes=1G
#EOF
#    
#    # Wipe the disk and create the new GPT table and partitions
#    systemd-repart --empty=force --definitions=/tmp/repart.d --dry-run=no "$disk"
#
#    # MUST WAIT for the kernel to recognize the new partitions
#    udevadm settle
#
#    # Identify and format the EFI partition
#    efi_partition=$(blkid | grep EFI | awk -F ':' '{print $1}')
#    mkfs.fat -F 32 "$efi_partition"
#  else
#    # Dual boot: Just append the BOOT and ROOT partitions to the unallocated space
#    systemd-repart --definitions=/tmp/repart.d --dry-run=no "$disk"
#    
#    # MUST WAIT for the kernel to recognize the new partitions
#    udevadm settle
#
#    # Identify existing EFI partition
#    efi_partition=$(blkid | grep EFI | awk -F ':' '{print $1}')
#  fi
#
#  # Identify our newly created partitions
#  boot_partition=$(blkid | grep BOOT | awk -F ':' '{print $1}')
#  root_partition=$(blkid | grep ROOT | awk -F ':' '{print $1}')
#
#  # Encrypt the root partition
#  echo -n "$luks_password" | cryptsetup luksFormat "$root_partition" -q --type luks2 --batch-mode
#  
#  # Unlock the root partition
#  echo -n "$luks_password" | cryptsetup open "$root_partition" cryptroot --key-file=-
#  
#  # Format the root partition
#  mkfs.btrfs -L archlinux /dev/mapper/cryptroot
#  mount /dev/mapper/cryptroot /mnt
#  
#  # Format and explicitly mount the boot partition as vfat
#  mkfs.fat -F 32 "$boot_partition"
#  mount -t vfat --mkdir "$boot_partition" /mnt/boot
#  
#  # Explicitly mount EFI partition as vfat
#  mount -t vfat -o umask=0077 --mkdir "$efi_partition" /mnt/efi
#  
#  # Install the base system
#  pacstrap -K /mnt base linux linux-firmware
#  
#  # Clean up temporary definitions
#  rm -rf /tmp/repart.d
#}
#
#write_pacman_hooks() {
#  mkdir -p /mnt/etc/pacman.d/hooks
#  cat << 'EOF' > /mnt/etc/pacman.d/hooks/90-kernel-install.hook
#[Trigger]
#Type = Path
#Operation = Install
#Operation = Upgrade
#Target = usr/lib/modules/*/vmlinuz
#
#[Action]
#Description = Installing kernel and generating UKI...
#When = PostTransaction
#Exec = /bin/sh -c 'for f in /usr/lib/modules/*/vmlinuz; do kver=$(basename $(dirname "$f")); kernel-install add "$kver" "$f"; done'
#NeedsTargets
#EOF
#  cat << EOF > /mnt/etc/pacman.d/hooks/95-systemd-boot.hook
#[Trigger]
#Type = Package
#Operation = Upgrade
#Target = systemd
#
#[Action]
#Description = Gracefully upgrading systemd-boot...
#When = PostTransaction
#Exec = /usr/bin/systemctl restart systemd-boot-update.service
#EOF
#  cat << 'EOF' > /mnt/etc/pacman.d/hooks/80-secureboot.hook
#[Trigger]
#Operation = Install
#Operation = Upgrade
#Type = Path
#Target = usr/lib/systemd/boot/efi/systemd-boot*.efi
#
#[Action]
#Description = Signing systemd-boot EFI binary for Secure Boot
#When = PostTransaction
#Exec = /bin/sh -c 'while read -r f; do /usr/lib/systemd/systemd-sbsign sign --private-key /etc/kernel/secure-boot-private-key.pem --certificate /etc/kernel/secure-boot-certificate.pem --output "${f}.signed" "$f"; done;'
#Depends = sh
#NeedsTargets
#EOF
#}
#
#write_kernel_configs() {
#  uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
#  mkdir -p /mnt/etc/kernel
# cat << EOF > /mnt/etc/kernel/cmdline
#rd.luks.name=UUID=${uuid}=cryptroot root=/dev/mapper/cryptroot rw splash quiet
#EOF
#  cat << EOF > /mnt/etc/kernel/install.conf
#layout=uki
#uki_generator=ukify
#initrd_generator=dracut
#EOF
#  cat << EOF > /mnt/etc/kernel/uki.conf
#[UKI]
#SecureBootSigningTool=systemd-sbsign
#SignKernel=true
#SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem
#SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem
#EOF
#}
#
#install_base_packages() {
#  # For nvidia: nvidia-open-dkms nvidia-utils lib32-nvidia-utils linux-firmware-nvidia
#  # For AMD: vulkan-radeon lib32-vulkan-radeon linux-firmware-amdgpu
#  pacstrap -K /mnt base-devel git systemd-ukify vim plymouth amd-ucode pipewire-jack tesseract-data-eng noto-fonts noto-fonts-cjk noto-fonts-emoji xdg-desktop-portal-kde qt6-multimedia-ffmpeg man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl dracut zram-generator rpcbind which cups gutenprint xorg-xwayland vulkan-tools steam gamemode lib32-gamemode lutris flatpak firewalld firefox libreoffice-fresh tuned mesa lib32-mesa pipewire wireplumber networkmanager plasma-meta system-config-printer tuned-ppd konsole dolphin kate skanpage gwenview plasma-systemmonitor khelpcenter sweeper partitionmanager kolourpaint ksystemlog isoimagewriter ktorrent ark kcalc spectacle hunspell hunspell-en_us 
#  ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
#}
#
#generate_chroot_script() {
#  cat << 'CHROOT_EOF' > /mnt/tmp/chroot_setup.sh
##!/bin/bash
#set -euo pipefail
#username=$1
#full_name=$2
#account_password=$3
#sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
#sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
#plymouth-set-default-theme spinfinity
#systemctl enable fstrim.timer
#systemctl enable systemd-oomd
#systemctl enable tuned
#systemctl enable tuned-ppd
#ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
#hwclock --systohc
#localectl set-keymap us
#cat << EOF > /etc/vconsole.conf
#KEYMAP=us
#FONT=eurlatgr
#EOF
#echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
#locale-gen
#echo "LANG=en_US.UTF-8" > /etc/locale.conf
#hostnamectl hostname arch
#cp /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/89-ethernet.network
#systemctl enable systemd-resolved
##systemctl enable systemd-networkd
#mkdir -p /etc/NetworkManager/conf.d
#cat << 'EOF' > /etc/NetworkManager/conf.d/dns.conf
#[main]
#dns=systemd-resolved
#EOF
#systemctl enable NetworkManager
#cat << EOF > /etc/systemd/zram-generator.conf
#[zram0]
#zram-size = min(ram / 2, 4096)
#compression-algorithm = zstd
#EOF
##echo 'omit_drivers+=" nouveau "' > /etc/dracut.conf.d/99-nouveau.conf
#sbctl create-keys
#sbctl enroll-keys -m
#cp /var/lib/sbctl/keys/db/db.key /etc/kernel/secure-boot-private-key.pem
#cp /var/lib/sbctl/keys/db/db.pem /etc/kernel/secure-boot-certificate.pem
#pacman -Rns --noconfirm sbctl
#rm -rf /var/lib/sbctl
#openssl x509 -in /etc/kernel/secure-boot-certificate.pem -outform DER -out /etc/kernel/secure-boot-certificate.der
#mkdir -p /var/lib/dkms
#ln -sf /etc/kernel/secure-boot-private-key.pem /var/lib/dkms/mok.key
#ln -sf /etc/kernel/secure-boot-certificate.der /var/lib/dkms/mok.pub
#uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
#echo "cryptroot UUID=$uuid none discard" > /etc/crypttab
#mkdir /etc/crypttab.d
#device_name=$(awk '{print $1}' /etc/crypttab)
#device_uuid=$(awk '{print $2}' /etc/crypttab)
#cat << EOF > /etc/crypttab.d/"${device_name}".conf
#NAME=$device_name
#DEVICE=$device_uuid
#OPTIONS=discard,tpm2-device=auto,x-initrd.attach
#EOF
## Can add module.sig_enforce=1 modprobe.blacklist=nouveau if wanted
#pacman -S --noconfirm systemd
#bootctl install
#systemctl enable systemd-homed.service
#ln -s /usr/bin/vim /usr/bin/vi
#echo "alias ll='ls -l' 2>/dev/null" > /etc/profile.d/ll.sh
#cat << EOF > /etc/systemd/system/firstboot-homed.service
#[Unit]
#Description=Create initial homed user
#After=systemd-homed.service
#Requires=systemd-homed.service
#ConditionPathExists=!/var/lib/systemd/home/$username.home
#
#[Service]
#Type=oneshot
## Feed the password to homectl via stdin to avoid exposing it in process lists
#ExecStart=/bin/bash -c "echo '${account_password}' | homectl create ${username} --storage=directory --group=${username} --member-of=wheel --shell=/bin/bash --real-name='${full_name}'"
## Delete this service file so the password isn't left on disk
#ExecStartPost=/usr/bin/rm /etc/systemd/system/firstboot-homed.service
#ExecStartPost=/usr/bin/systemctl disable firstboot-homed.service
#
#[Install]
#WantedBy=multi-user.target
#EOF
#systemctl enable firstboot-homed.service
#flatpak install -y com.heroicgameslauncher.hgl
## Install the right version of gamescope for Heroic Games Launcher
#heroic_runtime=$(flatpak list --columns=application,runtime|grep heroic|awk -F '/' '{print $3}')
#flatpak install -y flathub org.freedesktop.Platform.VulkanLayer.gamescope//"$heroic_runtime"
#flatpak install -y com.discordapp.Discord/x86_64/stable
#systemctl enable plasmalogin
#systemctl enable firewalld
#firewall-offline-cmd --new-zone=ArchWorkstation
#firewall-offline-cmd --zone=ArchWorkstation --set-description="Unsolicited incoming network packets are rejected..."
#firewall-offline-cmd --zone=ArchWorkstation --add-service=dhcpv6-client
#firewall-offline-cmd --zone=ArchWorkstation --add-port=1025-65535/udp
#firewall-offline-cmd --zone=ArchWorkstation --add-port=1025-65535/tcp
#firewall-offline-cmd --zone=ArchWorkstation --add-forward
#firewall-offline-cmd --set-default-zone=ArchWorkstation
##rm -f /etc/firewalld/firewalld.conf
##ln -s /etc/firewalld/firewalld-workstation.conf /etc/firewalld/firewalld.conf
#systemctl enable cups
#cat << 'EOF' > /usr/local/bin/firstboot-pcrlock.sh
##!/bin/bash
#set -euo pipefail
#
## 1. Generate the policy based on the actual bare-metal boot
#systemd-pcrlock make-policy
#
## 2. Find the backing physical drive using your existing logic
#drive=$(lsblk | grep -B 1 crypt | head -1 | awk -F '─' '{print $2}' | awk '{print $1}')
#
## 3. Enroll the LUKS drive using the generated policy
#systemd-cryptenroll --tpm2-device=auto --tpm2-pcrlock=/var/lib/systemd/pcrlock.json /dev/"$drive"
#EOF
#
#chmod +x /usr/local/bin/firstboot-pcrlock.sh
#
## Create the transient service to run the script
#cat << 'EOF' > /etc/systemd/system/firstboot-pcrlock.service
#[Unit]
#Description=First boot TPM policy generation and LUKS enrollment
#After=multi-user.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/firstboot-pcrlock.sh
## Clean up both the script and the service file so it never runs again
#ExecStartPost=/usr/bin/rm -f /usr/local/bin/firstboot-pcrlock.sh
#ExecStartPost=/usr/bin/rm -f /etc/systemd/system/firstboot-pcrlock.service
#ExecStartPost=/usr/bin/systemctl disable firstboot-pcrlock.service
#
#[Install]
#WantedBy=multi-user.target
#EOF
#
#systemctl enable firstboot-pcrlock.service
#bootctl install
#pacman -S --noconfirm linux
#CHROOT_EOF
#  chmod +x /mnt/tmp/chroot_setup.sh
#}
#
#execute_chroot() {
#  arch-chroot /mnt /bin/bash /tmp/chroot_setup.sh "$1" "$2" "$3"
#  rm -f /mnt/tmp/chroot_setup.sh
#}
#
#finalize_installation() {
#  umount -R /mnt
#  systemctl reboot
#}
#
#main() {
#  local luks_password
#  local username
#  local full_name
#  local account_password
#  read_input "Please provide a LUKS password:" "password" "luks_password"
#  read_input "Please provide a username for your account:" "username" "username"
#  read_input "Please provide your name as you wish it to be displayed:" "username" "full_name"
#  read_input "Please provide a password for your account:" "password" "account_password"
#  prepare_environment
#  drive_partitioning "$luks_password"
#  write_pacman_hooks
#  write_kernel_configs
#  install_base_packages
#  generate_chroot_script
#  execute_chroot "$username" "$full_name" "$account_password"
#  finalize_installation
#}
#
