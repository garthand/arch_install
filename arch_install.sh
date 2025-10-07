#!/bin/bash

loadkeys us
setfont Lat2-Terminus16
timedatectl set-timezone America/Chicago
timedatectl set-ntp true
# fdisk, partition 1G EFI and rest root partition x86_64 using fdisk or whatever you want
cryptsetup luksFormat /dev/sda2
cryptsetup open /dev/sda2 root
mkfs.btrfs -L archlinux /dev/mapper/root
mount /dev/mapper/root /mnt
mkfs.fat -F 32 /dev/sda1
mount -o umask=0077 --mkdir /dev/sda1 /mnt/boot
pacstrap -K /mnt base linux linux-firmware systemd-ukify vim amd-ucode man-db man-pages texinfo sof-firmware btrfs-progs shim mokutil
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
cat << EOF > /etc/pacman.d/hooks/80-secureboot.hook
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
openssl genrsa -out /etc/kernel/secure-boot-private-key.pem 2048
openssl req -new -x509 -sha256 -key /etc/kernel/secure-boot-private-key.pem -out /etc/kernel/secure-boot-certificate.pem -days 3650 -subj "/CN=My Secure Boot Key/"
openssl x509 -outform DER -in /etc/kernel/secure-boot-certificate.pem -out /etc/kernel/secure-boot-certificate.cer
kernel_version=$(ls /usr/lib/modules)
bootctl install
kernel-install add "$kernel_version" /usr/lib/modules/"$kernel_version"/vmlinuz
pacman -S --noconfirm systemd
bootctl install
mokutil --import /etc/kernel/secure-boot.certificate.cer
passwd root
