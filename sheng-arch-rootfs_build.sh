#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

DISTRO=$1; KERNEL=$2; TARGET_DE=${3:-gnome}
CUSTOM_USER=${4:-xiaomi}; CUSTOM_PASS=${5:-123456}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

[ "$TARGET_DE" = "all" ] && DESKTOPS=("gnome" "kde") || DESKTOPS=("$TARGET_DE")

cleanup_mounts() {
    fuser -k -9 -m rootdir 2>/dev/null || true
    sleep 2; umount -l rootdir/dev/pts 2>/dev/null || true
    umount -l rootdir/dev 2>/dev/null || true
    umount -l rootdir/proc 2>/dev/null || true
    umount -l rootdir/sys 2>/dev/null || true
    umount -l rootdir 2>/dev/null || true
    rm -rf rootdir
}
trap cleanup_mounts EXIT ERR INT TERM

for DE in "${DESKTOPS[@]}"; do
    ROOTFS_IMG="${DISTRO}_${DE}_${TIMESTAMP}.img"
    rm -f "$ROOTFS_IMG"; truncate -s $IMAGE_SIZE "$ROOTFS_IMG"; mkfs.ext4 -O ^metadata_csum "$ROOTFS_IMG" 
    mkdir -p rootdir; mount -o loop "$ROOTFS_IMG" rootdir

    [ ! -f "ArchLinuxARM-aarch64-latest.tar.gz" ] && wget -q http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
    bsdtar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C rootdir
    mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
    mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys

    echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf
    echo "Server = http://mirror.archlinuxarm.org/\$arch/\$repo" > rootdir/etc/pacman.d/mirrorlist
    chroot rootdir pacman-key --init; chroot rootdir pacman-key --populate archlinuxarm
    sed -i 's/^#DisableDownloadTimeout/DisableDownloadTimeout/' rootdir/etc/pacman.conf

    chroot rootdir pacman -Rdd --noconfirm linux-aarch64 linux-firmware || true
    chroot rootdir pacman -Syu --noconfirm base kmod glibc systemd sudo vim wget curl networkmanager wpa_supplicant dbus qrtr dialog

    if [ "$DE" = "gnome" ]; then
        chroot rootdir bash -c "pacman -Sgq gnome | grep -vE 'gnome-books|gnome-boxes' | pacman -S --noconfirm --needed - gdm gnome-tweaks"
        mkdir -p rootdir/etc/gdm
        printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm/custom.conf
        chroot rootdir systemctl enable gdm
    elif [ "$DE" = "kde" ]; then
        chroot rootdir pacman -S --noconfirm --needed plasma-meta sddm konsole
        mkdir -p rootdir/etc/sddm.conf.d
        printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
        chroot rootdir systemctl enable sddm
    fi
    chroot rootdir systemctl set-default graphical.target

    if ls *.deb 1> /dev/null 2>&1; then
        for pkg in *.deb; do dpkg-deb --fsys-tarfile "$pkg" | tar -x --keep-directory-symlink -C rootdir/; done
        KERNEL_MODULE_DIR=$(ls -1t rootdir/usr/lib/modules/ | head -n 1)
        if [ -n "$KERNEL_MODULE_DIR" ]; then
            chroot rootdir /usr/bin/depmod -a "$KERNEL_MODULE_DIR" || true
            chroot rootdir pacman -S --noconfirm --needed mkinitcpio
            sed -i 's/autodetect //g' rootdir/etc/mkinitcpio.conf
            chroot rootdir mkinitcpio -k "$KERNEL_MODULE_DIR" -g "/boot/initramfs-linux.img"
            [ -f "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" ] && cp "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" "rootdir/boot/Image"
        fi
    fi

    echo 'en_US.UTF-8 UTF-8' > rootdir/etc/locale.gen
    chroot rootdir /usr/bin/locale-gen
    chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
    chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER" || true
    chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
    chroot rootdir usermod -aG wheel,audio,video,input "$CUSTOM_USER"
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > rootdir/etc/sudoers.d/wheel
    chmod 440 rootdir/etc/sudoers.d/wheel

    chroot rootdir systemctl enable NetworkManager qrtr-ns || true
    mkdir -p rootdir/etc/udev/rules.d/
    printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules
    printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" > rootdir/etc/fstab
    chroot rootdir pacman -Scc --noconfirm

    cleanup_mounts; tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
    img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"; 7z a "${ROOTFS_IMG%.img}.7z" "sparse_${ROOTFS_IMG}"
    rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
done