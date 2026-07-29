#!/usr/bin/env bash
# arch-install-and-initialize.sh
# 集成脚本：安装系统 + 初始化系统 + 修复 NVIDIA 驱动

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[~]${NC} $1"; }

# ===================== 安装系统 (arch-install.sh) =====================

DISK_DEFAULT="/dev/nvme0n1"
EFI_PART="p1"
ROOT_PART="p2"
KERNEL_PKG="linux"
KERNEL_SELECTION="${KERNEL_PKG}"
BTRFS_SUBVOL_ROOT="@"
BTRFS_SUBVOL_HOME="@home"
ZRAM_SIZE_MB=4096
TIMEZONE="Asia/Shanghai"
LOCALES=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
HOSTNAME_DEFAULT="archlinux"

echo_err() { echo "$@" >&2; }

confirm() {
  local msg="$1"
  read -r -p "$msg [y/N]: " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

install_system() {
  echo
  warn "========== 安装 Arch Linux 系统 =========="
  warn "注意：此操作会格式化磁盘，仅在 Arch live 环境运行！"
  echo

  if [[ $(id -u) -ne 0 ]]; then
    err "此脚本必须以 root 身份运行（在 Arch live 环境中）"
    return 1
  fi

  local target_disk=""
  read -r -p "目标磁盘（默认: ${DISK_DEFAULT}）: " input_disk
  target_disk="${input_disk:-$DISK_DEFAULT}"
  echo "目标磁盘: $target_disk"

  if ! confirm "确认将对 $target_disk 执行操作并可能清除其上所有数据？（非常危险）"; then
    warn "已取消"
    return 1
  fi

  if confirm "是否用 cfdisk 手动分区（推荐）？"; then
    echo "请创建至少两个分区：EFI (~300M, type EFI) 和 Root (剩余空间)。完成后退出 cfdisk 继续。"
    cfdisk "$target_disk"
    if ! confirm "继续进行格式化并安装？"; then
      warn "已取消"
      return 1
    fi
  else
    echo "确保 $target_disk 已有合适分区：${target_disk}${EFI_PART} 和 ${target_disk}${ROOT_PART}"
    if ! confirm "继续（将格式化这些分区）？"; then
      warn "已取消"
      return 1
    fi
  fi

  local efi_dev="${target_disk}${EFI_PART}"
  local root_dev="${target_disk}${ROOT_PART}"

  echo "EFI 分区: $efi_dev"
  echo "Root 分区: $root_dev"

  info "格式化 EFI 分区为 FAT32 ..."
  mkfs.fat -F32 "$efi_dev"

  info "格式化 Root 分区为 btrfs ..."
  mkfs.btrfs -f "$root_dev"

  info "创建并挂载 btrfs 子卷 ..."
  mount -t btrfs "$root_dev" /mnt
  btrfs subvolume create /mnt/${BTRFS_SUBVOL_ROOT}
  btrfs subvolume create /mnt/${BTRFS_SUBVOL_HOME}
  umount /mnt

  mount -t btrfs -o subvol=${BTRFS_SUBVOL_ROOT},compress=zstd "$root_dev" /mnt
  mkdir -p /mnt/home
  mount -t btrfs -o subvol=${BTRFS_SUBVOL_HOME},compress=zstd "$root_dev" /mnt/home
  mkdir -p /mnt/efi
  mount --mkdir "$efi_dev" /mnt/efi

  if command -v reflector >/dev/null 2>&1; then
    info "使用 reflector 更新镜像源（中国优先）..."
    reflector --verbose --country China --latest 15 --sort rate --save /etc/pacman.d/mirrorlist || true
  fi

  info "选择内核 ..."
  local kernel_pkg=""
  read -r -p "内核 (linux/linux-zen/linux-lts，默认 linux): " input_kernel
  input_kernel="${input_kernel:-linux}"
  case "$input_kernel" in
    linux|linux-zen|linux-lts) kernel_pkg="$input_kernel" ;;
    *) kernel_pkg="linux" ;;
  esac

  PKGS=(base "${kernel_pkg}" linux-firmware base-devel vim networkmanager intel-ucode grub efibootmgr btrfs-progs git reflector os-prober zram-generator)
  info "开始 pacstrap 安装基础系统 ..."
  pacstrap /mnt ${PKGS[@]}

  info "生成 fstab ..."
  genfstab -U /mnt >> /mnt/etc/fstab

  cat > /mnt/root-setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

TIMEZONE="Asia/Shanghai"
LOCALES=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
HOSTNAME="archlinux"
ZRAM_SIZE_MB=4096

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

for locale in "${LOCALES[@]}"; do
  sed -i "s/^#\s\+\(${locale}\)/\1/" /etc/locale.gen || true
done
locale-gen

cat > /etc/locale.conf <<EOF
LANG=en_US.UTF-8
EOF

read -r -p "请输入主机名（默认: ${HOSTNAME}）: " input_hostname || true
if [[ -n "$input_hostname" ]]; then
  HOSTNAME="$input_hostname"
fi
echo "$HOSTNAME" > /etc/hostname

echo "请为 root 用户设置密码："
passwd root

if [ -d /sys/firmware/efi ]; then
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB || true
  grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "未检测到 UEFI 环境，请根据需要手动安装 grub。"
fi

systemctl enable NetworkManager

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
EOF

echo "chroot 内部配置完成。"
CHROOT_SCRIPT

  chmod +x /mnt/root-setup.sh
  info "进入 chroot 执行配置 ..."
  arch-chroot /mnt /root-setup.sh || err "arch-chroot 执行失败，请手动检查"

  log "系统安装完成！请执行: umount -R /mnt && reboot"
}

# ===================== 初始化系统 (initialize-arch.sh) =====================

configure_repos() {
  info "配置 multilib 仓库和 archlinuxcn 源 ..."
  if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
  else
    sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf
  fi
  if ! grep -q "^\[archlinuxcn\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<EOF

[archlinuxcn]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch
Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch
EOF
  fi
  log "仓库配置完成"
}

install_btrfs_tools() {
  info "安装 archlinuxcn-keyring ..."
  pacman -Sy --noconfirm archlinuxcn-keyring
  info "安装 btrfs 快照工具 ..."
  pacman -S --needed --noconfirm snapper snap-pac btrfs-progs btrfs-assistant grub-btrfs inotify-tools
  snapper -c root create-config /
  snapper -c home create-config /home
  systemctl enable --now grub-btrfsd
  log "btrfs 快照工具安装配置完成"
}

install_lts_kernel() {
  info "安装 linux-lts 内核 ..."
  pacman -S --noconfirm linux-lts
  snapper -c root create -d "Initial snapshot"
  snapper -c home create -d "Initial snapshot"
  grub-mkconfig -o /boot/grub/grub.cfg
  log "linux-lts 内核及快照完成"
}

install_gpu_drivers() {
  info "安装 NVIDIA 驱动 ..."
  pacman -S --noconfirm linux-zen-headers linux-lts-headers nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
  info "安装 Intel 显卡驱动 ..."
  pacman -S --needed --noconfirm mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  info "安装视频编解码 ..."
  pacman -S --needed --noconfirm nvidia-utils libva-nvidia-driver intel-media-driver
  log "显卡驱动安装完成"
}

install_multimedia() {
  info "安装音视频服务 ..."
  pacman -S --needed --noconfirm sof-firmware alsa-ucm-conf alsa-firmware pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack
  local user="${SUDO_USER:-$USER}"
  if id "$user" &>/dev/null; then
    su -c "systemctl --user enable --now pipewire pipewire-pulse wireplumber" "$user" 2>/dev/null || true
  fi
  info "安装蓝牙服务 ..."
  pacman -S --needed --noconfirm bluez
  systemctl enable --now bluetooth
  log "多媒体服务安装完成"
}

install_fonts() {
  info "安装字体 ..."
  pacman -S --needed --noconfirm noto-fonts noto-fonts-emoji adobe-source-han-sans-cn-fonts
  log "字体安装完成"
}

install_flatpak() {
  info "安装 flatpak ..."
  pacman -S --needed --noconfirm flatpak
  log "flatpak 安装完成"
}

install_yay() {
  info "安装 yay (AUR 助手) ..."
  pacman -S --needed yay
  log "yay 安装完成"
}

create_final_snapshot() {
  snapper -c root create -d "Initial archlinux done"
  snapper -c home create -d "Initial archlinux done"
  log "最终快照已创建"
}

initialize_system() {
  echo
  warn "========== 初始化系统（配置源、驱动、多媒体等） =========="
  echo

  if [[ $EUID -ne 0 ]]; then
    err "请以 root 权限运行"
    return 1
  fi

  configure_repos
  install_yay
  install_btrfs_tools
  install_lts_kernel
  install_gpu_drivers
  install_multimedia
  install_fonts
  install_flatpak
  create_final_snapshot

  log "系统初始化完成！建议重启。"
}

# ===================== 修复 NVIDIA 0x00000025 =====================

fix_nvidia_error() {
  echo
  warn "========== 修复 NVIDIA 驱动 0x00000025 报错 =========="
  echo

  if [[ $EUID -ne 0 ]]; then
    err "请以 root 权限运行"
    return 1
  fi

  info "配置 /etc/modprobe.d/nvidia-open.conf ..."
  cat > /etc/modprobe.d/nvidia-open.conf <<EOF
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_EnableS0ixPowerManagement=0
options nvidia NVreg_RegistryDwords=EnableS0ixPowerManagement=0
options nvidia NVreg_InitializeSystemMemoryAllocations=1
options nvidia NVreg_UsePlatformInterface=1
EOF
  log "nvidia-open.conf 配置完成"

  info "修改内核引导参数 ..."
  if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 acpi_enforce_resources=lax pcie_aspm=off"/' /etc/default/grub
  fi
  log "内核引导参数已添加"

  info "重新编译 nvidia-open-dkms ..."
  if command -v dkms &>/dev/null; then
    dkms autoinstall -k "$(uname -r)" 2>/dev/null || true
  fi
  pacman -S --noconfirm nvidia-open-dkms

  info "更新 GRUB 和 initramfs ..."
  grub-mkconfig -o /boot/grub/grub.cfg
  mkinitcpio -P

  log "NVIDIA 驱动 0x00000025 修复完成！"
  warn "请执行 shutdown -h now 断电冷启动以使修复生效"
}

# ===================== 主菜单 =====================

check_network() {
  if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    err "网络连接异常，请确保设备已联网"
    exit 1
  fi
}

show_menu() {
  clear
  echo "=============================================="
  echo "      Arch Linux 安装与初始化集成脚本"
  echo "=============================================="
  echo
  echo "  1. 安装系统（分区/格式化/pacstrap/chroot）"
  echo "     - 在 Arch live 环境中运行"
  echo "  2. 初始化系统（配置源/驱动/多媒体/字体等）"
  echo "     - 在已安装的 Arch 系统中运行"
  echo "  3. 修复 NVIDIA 驱动 0x00000025 报错"
  echo "  4. 重启系统"
  echo "  5. 关机（冷启动）"
  echo "  0. 退出"
  echo
  echo "=============================================="
  echo
}

main() {
  while true; do
    show_menu
    read -rp "请输入选项 [0-5]: " choice
    case $choice in
      1)
        install_system
        ;;
      2)
        initialize_system
        ;;
      3)
        fix_nvidia_error
        ;;
      4)
        reboot
        ;;
      5)
        shutdown -h now
        ;;
      0)
        info "退出脚本"
        exit 0
        ;;
      *)
        warn "无效选项，请重新输入"
        ;;
    esac
    echo
    read -rp "按回车键返回主菜单..."
  done
}

main "$@"
