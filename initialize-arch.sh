#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[~]${NC} $1"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请以root权限运行此脚本"
    exit 1
  fi
}

check_network() {
  if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    err "网络连接异常，请确保设备已联网"
    exit 1
  fi
  log "网络连接正常"
}

configure_repos() {
  info "正在配置 multilib 仓库和 archlinuxcn 源 ..."

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

install_base() {
  info "正在安装 archlinuxcn-keyring ..."
  pacman -Sy --noconfirm archlinuxcn-keyring
  log "archlinuxcn-keyring 安装完成"

  info "正在安装 btrfs 快照工具 ..."
  pacman -S --needed --noconfirm snapper snap-pac btrfs-progs btrfs-assistant grub-btrfs inotify-tools
  log "btrfs 快照工具安装完成"

  snapper -c root create-config /
  snapper -c home create-config /home
  log "snapper 配置完成"

  systemctl enable --now grub-btrfsd
  log "grub-btrfsd 已启用"
}

install_kernel() {
  info "正在安装 linux-lts 内核 ..."
  pacman -S --noconfirm linux-lts
  log "linux-lts 内核安装完成"

  snapper -c root create -d "Initial snapshot"
  snapper -c home create -d "Initial snapshot"
  log "初始快照已创建"

  grub-mkconfig -o /boot/grub/grub.cfg
  log "GRUB 已更新"
}

install_gpu_drivers() {
  info "正在安装 NVIDIA 驱动 ..."
  pacman -S --noconfirm linux-zen-headers linux-lts-headers nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
  log "NVIDIA 驱动安装完成"

  info "正在安装 Intel 显卡驱动 ..."
  pacman -S --needed --noconfirm mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  log "Intel 显卡驱动安装完成"

  info "正在安装视频编解码 ..."
  pacman -S --needed --noconfirm nvidia-utils libva-nvidia-driver intel-media-driver
  log "视频编解码安装完成"
}

install_multimedia() {
  info "正在安装音视频服务 ..."
  pacman -S --needed --noconfirm sof-firmware alsa-ucm-conf alsa-firmware pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack

  su -c "systemctl --user enable --now pipewire pipewire-pulse wireplumber" "$SUDO_USER"
  log "音视频服务安装并启用完成"

  info "正在安装蓝牙服务 ..."
  pacman -S --needed --noconfirm bluez
  systemctl enable --now bluetooth
  log "蓝牙服务安装并启用完成"
}

install_fonts() {
  info "正在安装字体 ..."
  pacman -S --needed --noconfirm noto-fonts noto-fonts-emoji adobe-source-han-sans-cn-fonts
  log "字体安装完成"
}

install_flatpak() {
  info "正在安装 flatpak ..."
  pacman -S --needed --noconfirm flatpak
  log "flatpak 安装完成"
}

create_final_snapshot() {
  snapper -c root create -d "Initial archlinux done"
  snapper -c home create -d "Initial archlinux done"
  log "最终快照已创建"
}

full_install() {
  echo
  warn "========== 开始完整安装（不包含 nvidia 0x00000025 修复） =========="
  echo

  configure_repos
  install_base
  install_kernel
  install_gpu_drivers
  install_multimedia
  install_fonts
  install_flatpak
  create_final_snapshot

  echo
  log "完整安装完成！建议重启系统。"
  warn "如需修复 nvidia 0x00000025 报错，请运行本脚本的选项 2"
}

fix_nvidia_error() {
  echo
  warn "========== 修复 NVIDIA 驱动 0x00000025 报错 =========="
  echo

  info "正在配置 /etc/modprobe.d/nvidia-open.conf ..."
  cat > /etc/modprobe.d/nvidia-open.conf <<EOF
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_EnableS0ixPowerManagement=0
options nvidia NVreg_RegistryDwords=EnableS0ixPowerManagement=0
options nvidia NVreg_InitializeSystemMemoryAllocations=1
options nvidia NVreg_UsePlatformInterface=1
EOF
  log "nvidia-open.conf 配置完成"

  info "正在修改内核引导参数 ..."
  if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 acpi_enforce_resources=lax pcie_aspm=off"/' /etc/default/grub
  fi
  log "内核引导参数已添加"

  info "正在强制重新编译 nvidia-open-dkms ..."
  if command -v dkms &>/dev/null; then
    dkms autoinstall -k "$(uname -r)" 2>/dev/null || true
  fi
  pacman -S --noconfirm nvidia-open-dkms
  log "nvidia-open-dkms 重新编译完成"

  info "正在更新 GRUB 和 initramfs ..."
  grub-mkconfig -o /boot/grub/grub.cfg
  mkinitcpio -P
  log "GRUB 和 initramfs 更新完成"

  echo
  log "NVIDIA 驱动 0x00000025 修复完成！"
  warn "请执行 shutdown -h now 断电冷启动以使修复生效"
}

show_menu() {
  clear
  echo "=========================================="
  echo "         Arch Linux 安装配置脚本"
  echo "=========================================="
  echo
  echo "  1. 完整安装（配置源、内核、驱动、多媒体等）"
  echo "  2. 修复 NVIDIA 驱动 0x00000025 报错"
  echo "  3. 重启系统"
  echo "  4. 关机（冷启动）"
  echo "  0. 退出"
  echo
  echo "=========================================="
  echo
}

main() {
  # 非 root 时自动提权
  if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
  fi

  check_network

  while true; do
    show_menu
    read -rp "请输入选项 [0-4]: " choice
    case $choice in
      1)
        full_install
        ;;
      2)
        fix_nvidia_error
        ;;
      3)
        reboot
        ;;
      4)
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
