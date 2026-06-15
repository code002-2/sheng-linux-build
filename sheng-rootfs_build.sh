#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

if [ $# -lt 2 ]; then exit 1; fi
if [ "$(id -u)" -ne 0 ]; then exit 1; fi

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-all}
TARGET_FLAVOUR=${4:-all} 
CUSTOM_USER=${5:-xiaomi}
CUSTOM_PASS=${6:-123456}

distro_version="trixie"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

BOOTMODES=("$TARGET_MODE")
FLAVOURS=("$TARGET_FLAVOUR")

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

for FLAVOUR in "${FLAVOURS[@]}"; do
    for MODE in "${BOOTMODES[@]}"; do
        ROOTFS_IMG="debian_${distro_version}_${FLAVOUR}_${MODE}_${TIMESTAMP}.img"
        cleanup_mounts; mkdir -p rootdir
        truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
        mkfs.ext4 -O ^metadata_csum "$ROOTFS_IMG"
        mount -o loop "$ROOTFS_IMG" rootdir

        debootstrap --arch=arm64 "$distro_version" rootdir http://deb.debian.org/debian/
        mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
        mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys

        echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends systemd sudo vim wget curl network-manager openssh-server wpasupplicant dbus locales dialog"

        sed -i 's/^# *\(en_US.UTF-8\)/\1/' rootdir/etc/locale.gen
        sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' rootdir/etc/locale.gen
        chroot rootdir locale-gen
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/default/locale
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/locale.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y fonts-noto-cjk fonts-wqy-microhei fcitx5 fcitx5-chinese-addons"

        cp *.deb rootdir/tmp/ 2>/dev/null || true
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y libglib2.0-0 libprotobuf-c1 libqmi-glib5 libmbim-glib4 initramfs-tools"
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y /tmp/*.deb" || true
        
        chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
        echo "debian-$FLAVOUR-$MODE" > rootdir/etc/hostname

        chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER" || true
        chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
        chroot rootdir usermod -aG sudo,audio,video,input "$CUSTOM_USER"

        if [ "$FLAVOUR" = "gnome" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y gnome-shell gnome-session gnome-terminal gdm3"
            mkdir -p rootdir/etc/gdm3
            printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm3/daemon.conf
            chroot rootdir systemctl enable gdm3
        elif [ "$FLAVOUR" = "kde" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y kde-standard sddm"
            mkdir -p rootdir/etc/sddm.conf.d
            printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
            chroot rootdir systemctl enable sddm
        fi
        chroot rootdir systemctl enable NetworkManager
        chroot rootdir systemctl set-default graphical.target

        [ "$MODE" = "dual" ] && echo "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab || echo "PARTLABEL=userdata / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab

        chroot rootdir apt-get clean; rm -f rootdir/tmp/*.deb
        cleanup_mounts; tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
        img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
        7z a "${ROOTFS_IMG%.img}.7z" "sparse_${ROOTFS_IMG}"
        rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
    done
done
trap - EXIT ERR INT TERM