#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
ESP="${DISK}p1"
ROOT_PART="${DISK}p5"
ROOT_START="200GiB"
ROOT_END="+40GiB"
SWAP_SIZE="8G"
HOSTNAME="arch-dualboot"
LOCALE1="fr_FR.UTF-8"
LOCALE2="en_US.UTF-8"
USERNAME="user"

printf "%s\n" \
"/dev/nvme0n1p1  ESP(FAT32) -> /boot/efi [Windows+Arch]" \
"/dev/nvme0n1p5  LUKS -> ext4 /" \
"/swapfile       in / -> swap"

timedatectl set-ntp true

parted -s "$DISK" print
parted -s "$DISK" -- mkpart LINUX_ROOT "$ROOT_START" "$ROOT_END"
parted -s "$DISK" print

cryptsetup luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot
mkfs.ext4 -L arch_root /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi

pacstrap -K /mnt base linux linux-firmware vim networkmanager grub efibootmgr cryptsetup os-prober

genfstab -U /mnt >> /mnt/etc/fstab

LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

arch-chroot /mnt /bin/bash -euxo pipefail -c "
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -i 's/^#\(${LOCALE1}\)/\1/' /etc/locale.gen
sed -i 's/^#\(${LOCALE2}\)/\1/' /etc/locale.gen
locale-gen
printf 'LANG=%s\n' '${LOCALE1}' > /etc/locale.conf
printf '%s\n' '${HOSTNAME}' > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
systemctl enable NetworkManager
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
sed -i \"s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\\\"cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rw\\\"|\" /etc/default/grub
grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
os-prober || true
grub-mkconfig -o /boot/grub/grub.cfg
fallocate -l ${SWAP_SIZE} /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab
swapon -a
passwd -d root || true
id -u ${USERNAME} >/dev/null 2>&1 || useradd -m -G wheel ${USERNAME}
passwd -d ${USERNAME} || true
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
"

echo "OK"

