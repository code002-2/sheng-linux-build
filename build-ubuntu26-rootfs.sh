#!/bin/bash
set -e

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

UBUNTU_SUITE="resolute"
UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"

if [ $# -lt 2 ]; then
    echo "用法: $0 <kernel_version> <desktop_environment> [username] [password] [boot_mode]"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then exit 1; fi

KERNEL=$1
DESKTOP_ENV=$2
CUSTOM_USER=${3:-xiaomi}
CUSTOM_PASS=${4:-123456}
BOOT_MODE=${5:-dual}

# 解析单双系统启动模式
if [ "$BOOT_MODE" = "single" ]; then
    ROOT_PART="userdata"
    IMG_SUFFIX="singleboot"
else
    ROOT_PART="linux"
    IMG_SUFFIX="dualboot"
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="ubuntu26_${DESKTOP_ENV}_${IMG_SUFFIX}_${TIMESTAMP}.img"

echo "开始构建 Ubuntu 26.04 | 桌面: $DESKTOP_ENV | 模式: $BOOT_MODE | 用户: $CUSTOM_USER"

rm -rf rootdir || true
truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir
mount -o loop "$ROOTFS_IMG" rootdir

debootstrap --arch=arm64 "$UBUNTU_SUITE" rootdir "$UBUNTU_MIRROR"

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

printf "deb %s %s main restricted universe multiverse\n" "$UBUNTU_MIRROR" "$UBUNTU_SUITE" > rootdir/etc/apt/sources.list
printf "deb %s %s-updates main restricted universe multiverse\n" "$UBUNTU_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list
printf "deb %s %s-security main restricted universe multiverse\n" "$UBUNTU_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list

chroot rootdir apt update
# ✅ 确保包含 openssh-server
chroot rootdir apt install -y --no-install-recommends \
    systemd sudo vim-tiny wget curl network-manager openssh-server \
    wpasupplicant dbus kmod initramfs-tools

if ls *.deb 1> /dev/null 2>&1; then
    cp *.deb rootdir/tmp/
    chroot rootdir bash -c "apt install -y /tmp/*.deb || true"
    KERNEL_MODULE_DIR=$(ls rootdir/lib/modules/ | head -n 1)
    if [ -n "$KERNEL_MODULE_DIR" ]; then
        chroot rootdir /sbin/depmod -a "$KERNEL_MODULE_DIR" || true
    fi
fi

chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
chroot rootdir locale-gen en_US.UTF-8
chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
echo "ubuntu26-${DESKTOP_ENV}" > rootdir/etc/hostname

if [ "$DESKTOP_ENV" = "gnome" ]; then
    chroot rootdir apt install -y --no-install-recommends ubuntu-desktop-minimal gnome-terminal firefox gdm3
    DM="gdm3"
elif [ "$DESKTOP_ENV" = "kde" ]; then
    chroot rootdir apt install -y --no-install-recommends plasma-desktop sddm konsole firefox plasma-workspace
    DM="sddm"
elif [ "$DESKTOP_ENV" = "xfce" ]; then
    chroot rootdir apt install -y --no-install-recommends xfce4 xfce4-terminal lightdm lightdm-gtk-greeter
    DM="lightdm"
fi

chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER"
echo "$CUSTOM_USER:$CUSTOM_PASS" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo,audio,video,render,input,plugdev "$CUSTOM_USER"

chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
ln -sf /lib/systemd/system/getty@.service rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service
# ✅ 强制启用 SSH
chroot rootdir systemctl enable systemd-resolved ssh
ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

FW_DIR="rootdir/lib/firmware/ath12k/WCN7850/hw2.0"
if [ -f "$FW_DIR/board-2.bin" ]; then cp "$FW_DIR/board-2.bin" "$FW_DIR/board.bin"; fi
chroot rootdir apt install -y qrtr-tools || true
chroot rootdir systemctl enable qrtr-ns || true

if [ "$DM" = "gdm3" ]; then
    mkdir -p rootdir/etc/gdm3
    printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm3/daemon.conf
    chroot rootdir systemctl enable gdm3
fi
if [ "$DM" = "sddm" ]; then
    mkdir -p rootdir/etc/sddm.conf.d
    printf "[General]\nDisplayServer=x11\nInputMethod=\n" > rootdir/etc/sddm.conf.d/ubuntu-defaults.conf
    printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
    chroot rootdir systemctl enable sddm
fi
if [ "$DM" = "lightdm" ]; then
    mkdir -p rootdir/etc/lightdm/lightdm.conf.d
    printf "[Seat:*]\nautologin-user=$CUSTOM_USER\nautologin-user-timeout=0\n" > rootdir/etc/lightdm/lightdm.conf.d/autologin.conf
    chroot rootdir systemctl enable lightdm
fi

chroot rootdir systemctl set-default graphical.target

# ✅ 写入单/双系统对应的 fstab
printf "PARTLABEL=%s / ext4 defaults,noatime,errors=remount-ro 0 1\n" "$ROOT_PART" > rootdir/etc/fstab

chroot rootdir apt clean
chroot rootdir rm -rf /tmp/*.deb

umount rootdir/dev/pts || true
umount rootdir/dev || true
umount rootdir/proc || true
umount rootdir/sys || true
umount rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
SPARSE_IMG="sparse_${ROOTFS_IMG}"
img2simg "$ROOTFS_IMG" "$SPARSE_IMG"
7z a "ubuntu26_${DESKTOP_ENV}_${IMG_SUFFIX}_${TIMESTAMP}.7z" "$SPARSE_IMG"
rm -f "$ROOTFS_IMG" "$SPARSE_IMG"
