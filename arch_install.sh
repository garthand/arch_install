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
# For nvidia: nvidia-open-dkms nvidia-utils lib32-nvidia-utils linux-firmware-nvidia
# For AMD: vulkan-radeon lib32-vulkan-radeon linux-firmware-amdgpu
sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
pacstrap -K /mnt base base-devel git linux linux-firmware systemd-ukify vim amd-ucode man-db man-pages texinfo sof-firmware btrfs-progs cryptsetup sbctl dracut sudo zram-generator rpcbind which xorg-xwayland vulkan-tools steam gamemode lib32-gamemode lutris flatpak dash firewalld dash firefox libreoffice-fresh mesa lib32-mesa pipewire wireplumber networkmanager plasma-meta konsole dolphin kate skanpage gwenview plasma-systemmonitor khelpcenter sweeper partitionmanager kolourpaint ksystemlog isoimagewriter ktorrent ark kcalc spectacle hunspell hunspell-en_us 
ln -sf ../run/NetworkManager/resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt
sed -i '/^#\[multilib\]$/ {n; s/.*/Include = \/etc\/pacman\.d\/mirrorlist/}' /mnt/etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /mnt/etc/pacman.conf
systemctl enable fstrim.timer
systemctl enable systemd-oomd
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
ukify build --linux /boot/vmlinuz-linux --initrd /boot/initramfs-linux.img --cmdline "rd.luks.name=UUID=$uuid=cryptroot root=/dev/mapper/cryptroot rw" --output /boot/EFI/Linux/linux-arch.efi --sign-kernel --secureboot-private-key=/etc/kernel/secure-boot-private-key.pem --secureboot-certificate=/etc/kernel/secure-boot-certificate.pem --signtool=systemd-sbsign --uname=$kernel_version
pacman -S --noconfirm systemd
bootctl install
systemctl enable systemd-homed.service
ln -s /usr/bin/vim /usr/bin/vi
echo "alias ll='ls -l' 2>/dev/null" > /etc/profile.d/ll.sh
#homectl create testuser --storage=directory --group=testuser --member-of=wheel --shell=/bin/bash --real-name="Test User" --password
useradd testuser -m -G wheel -s "/bin/bash" -c "Test User" -p $(openssl passwd -6 "password")
# Symlink Steam Proton to Heroic Games Launcher
flatpak install -y com.heroicgameslauncher.hgl
ln -s ~/.steam/steam/steamapps/common/Proton\ -\ Experimental/ ~/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton/Steam-Proton-Experimental
# Symlink GE Proton to Steam
ln -s ~/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton/GE-Proton-latest/ ~/.steam/steam/compatibilitytools.d/GE-Proton-latest
# Install the right version of gamescope for Heroic Games Launcher
heroic_runtime=$(flatpak list --columns=application,runtime|grep heroic|awk -F '/' '{print $3}')
flatpak install -y flathub org.freedesktop.Platform.VulkanLayer.gamescope//"$heroic_runtime"
flatpak install -y com.discordapp.Discord/x86_64/stable
systemctl enable sddm
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
pacman -S --noconfirm cups gutenprint
systemctl enable cups
#drive=$(lsblk|grep -B 1 crypt|head -1|awk -F '─' '{print $2}'|awk '{print $1}')
#systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/"$drive"
