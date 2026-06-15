#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
FEDORA_VERSION="44" 

DISTRO=$1; KERNEL=$2; DESKTOP_ENV=${3:-gnome}
CUSTOM_USER=${4:-xiaomi}; CUSTOM_PASS=${5:-123456}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="fedora_desktop_${DESKTOP_ENV}_${TIMESTAMP}.img"

rm -rf rootdir || true; truncate -s $IMAGE_SIZE "$ROOTFS_IMG"; mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir; mount -o loop "$ROOTFS_IMG" rootdir

docker pull --platform linux/arm64 fedora:${FEDORA_VERSION}
docker create --name fedora-temp fedora:${FEDORA_VERSION}
docker export fedora-temp | tar -x -C rootdir/; docker rm fedora-temp

mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys
echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf

chroot rootdir dnf -y install git gcc make kernel-headers
chroot rootdir dnf -y update --exclude=kernel-core
chroot rootdir dnf -y install --exclude=kernel-core systemd sudo vim wget curl tar xz pciutils findutils NetworkManager wpa_supplicant dialog qrtr

if [ "$DESKTOP_ENV" = "gnome" ]; then
    chroot rootdir dnf -y install @gnome-desktop --exclude=kernel-core
    chroot rootdir dnf -y install gdm
    mkdir -p rootdir/etc/gdm
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm/custom.conf
    chroot rootdir systemctl enable gdm
elif [ "$DESKTOP_ENV" = "kde" ]; then
    chroot rootdir dnf -y install @kde-desktop --exclude=kernel-core
    chroot rootdir dnf -y install sddm
    mkdir -p rootdir/etc/sddm.conf.d
    printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
    chroot rootdir systemctl enable sddm
fi

if ls *.deb 1> /dev/null 2>&1; then
    for pkg in *.deb; do dpkg-deb --fsys-tarfile "$pkg" | tar -x --keep-directory-symlink -C rootdir/; done
    KERNEL_MODULE_DIR=$(ls -1t rootdir/usr/lib/modules/ | head -n 1)
    if [ -n "$KERNEL_MODULE_DIR" ]; then
        chroot rootdir /usr/sbin/depmod -a "$KERNEL_MODULE_DIR" || true
        chroot rootdir dnf -y install dracut
        chroot rootdir dracut -N --kver "$KERNEL_MODULE_DIR" --force "/boot/initramfs-linux.img"
        [ -f "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" ] && cp "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" "rootdir/boot/Image"
    fi
fi

chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER"
chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
chroot rootdir usermod -aG wheel,audio,video,input "$CUSTOM_USER"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > rootdir/etc/sudoers.d/wheel
chmod 440 rootdir/etc/sudoers.d/wheel

mkdir -p rootdir/etc/selinux
echo "SELINUX=disabled" > rootdir/etc/selinux/config
chroot rootdir systemctl enable NetworkManager qrtr
chroot rootdir systemctl set-default graphical.target
printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" > rootdir/etc/fstab

chroot rootdir dnf clean all
fuser -k -9 -m rootdir || true; sleep 2
umount -l rootdir/dev/pts || true; umount -l rootdir/dev || true; umount -l rootdir/proc || true; umount -l rootdir/sys || true; umount -l rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"; 7z a "fedora_desktop_${DESKTOP_ENV}_${TIMESTAMP}.7z" "sparse_${ROOTFS_IMG}"
rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"