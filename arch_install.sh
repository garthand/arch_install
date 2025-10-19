#!/bin/bash

loadkeys us
setfont Lat2-Terminus16
timedatectl set-timezone America/Chicago
timedatectl set-ntp true
sgdisk --zap-all /dev/sda
sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI" /dev/sda
sgdisk -n2:0:0   -t2:8304 -c2:"ROOT" /dev/sda
echo -n "password" | cryptsetup luksFormat /dev/sda2 -q --type luks2 --batch-mode
echo -n "password" | cryptsetup open /dev/sda2 cryptroot --key-file=-
mkfs.btrfs -L archlinux /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
mkfs.fat -F 32 /dev/sda1
mount -o umask=0077 --mkdir /dev/sda1 /mnt/boot
pacstrap -K /mnt base linux linux-firmware systemd-ukify vim amd-ucode man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl dracut sudo zram-generator rpcbind which gnome xorg-xwayland vulkan-tools lib32-vulkan-tools steam gamemode lib32-gamemode lutris
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc
localectl set-keymap us
cat << EOF > /etc/vconsole.conf
KEYMAP=us
FONT=Lat2-Terminus16
EOF
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
hostnamectl hostname arch
cp /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/89-ethernet.network
systemctl enable systemd-resolved
systemctl enable systemd-networkd
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
sbctl create-keys
sbctl enroll-keys -m
cp /var/lib/sbctl/keys/db/db.key /etc/kernel/secure-boot-private-key.pem
cp /var/lib/sbctl/keys/db/db.pem /etc/kernel/secure-boot-certificate.pem
pacman -Rns --noconfirm sbctl
rm -rf /var/lib/sbctl
uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
echo "cryptroot UUID=$uuid none discard" > /etc/crypttab
kernel_version=$(ls /usr/lib/modules)
bootctl install
dracut --kver "$kernel_version" --force /boot/initramfs-linux.img
ukify build --linux /boot/vmlinuz-linux --initrd /boot/initramfs-linux.img --cmdline "rd.luks.name=UUID=$uuid=cryptroot root=/dev/mapper/cryptroot rw" --output /boot/EFI/Linux/linux-arch.efi --sign-kernel --secureboot-private-key=/etc/kernel/secure-boot-private-key.pem --secureboot-certificate=/etc/kernel/secure-boot-certificate.pem --signtool=systemd-sbsign --uname=$kernel_version
pacman -S --noconfirm systemd
bootctl install
systemctl enable systemd-homed.service
ln -s /usr/bin/vim /usr/bin/vi
echo "alias ll='ls -l' 2>/dev/null" > /etc/profile.d/ll.sh
#homectl create testuser --storage=directory --group=testuser --member-of=wheel --shell=/bin/bash --real-name="Test User" --password
systemctl mask brltty
useradd testuser -m -G wheel -s "/bin/bash" -c "Test User" -p $(openssl passwd -6 "password")
