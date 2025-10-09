#!/bin/bash

loadkeys us
setfont Lat2-Terminus16
timedatectl set-timezone America/Chicago
timedatectl set-ntp true
sgdisk --zap-all /dev/sda
sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI System" /dev/sda
sgdisk -n2:0:0   -t2:8304 -c2:"Linux root" /dev/sda
cryptsetup luksFormat /dev/sda2
cryptsetup open /dev/sda2 root
mkfs.btrfs -L archlinux /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
mkfs.fat -F 32 /dev/sda1
mount -o umask=0077 --mkdir /dev/sda1 /mnt/boot
pacstrap -K /mnt base linux linux-firmware systemd-ukify vim amd-ucode man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl
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
cat << EOF > /etc/kernel/uki.conf
[UKI]
Splash=/usr/share/systemd/bootctl/splash-arch.bmp
SecureBootSigningTool=systemd-sbsign
SignKernel=true
SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem
SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem
EOF
cat << EOF > /etc/kernel/install.conf
layout=uki
EOF
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
sbctl create-keys
sbctl enroll-keys -m
cp /var/lib/sbctl/keys/db/db.key /etc/kernel/secure-boot-private-key.pem
cp /var/lib/sbctl/keys/db/db.pem /etc/kernel/secure-boot-certificate.pem
pacman -Rns --noconfirm sbctl
rm -rf /var/lib/sbctl
uuid=$(blkid|grep LUKS|awk -F '"' '{print $2}')
echo "cryptdevice=UUID=$uuid:cryptroot root=/dev/mapper/cryptroot rw" > /etc/kernel/cmdline
echo "cryptroot /dev/disk/by-uuid/$uuid none timeout=180" > /etc/crypttab.initramfs
echo HOOKS=(base systemd microcode modconf kms keyboard keymap consolefont block filesystems btrfs sd-encrypt fsck) > /etc/mkinitcpio.conf
kernel_version=$(ls /usr/lib/modules)
mkinitcpio -k "$kernel_version" -g /boot/initramfs-linux.img
bootctl install
kernel-install add "$kernel_version" /usr/lib/modules/"$kernel_version"/vmlinuz
pacman -S --noconfirm systemd
bootctl install
passwd root
