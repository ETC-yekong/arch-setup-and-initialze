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

# Language detection
UI_LANG="en"
case "${LANG:-}" in zh*) UI_LANG="zh" ;; esac
# TERM=linux 时强制英文（Linux 控制台无 CJK 字体，显示豆腐块）
[ "${TERM:-}" = "linux" ] && UI_LANG="en"
__() { [ "$UI_LANG" = "zh" ] && echo "$1" || echo "$2"; }

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
  warn "$(__ "========== 安装 Arch Linux 系统 ==========" "========== Install Arch Linux System ==========")"
  warn "$(__ "注意：此操作会格式化磁盘，仅在 Arch live 环境运行！" "Warning: This will format the disk. Only run in Arch live environment!")"
  echo

  if [[ $(id -u) -ne 0 ]]; then
    err "$(__ "此脚本必须以 root 身份运行（在 Arch live 环境中）" "This script must be run as root (in Arch live environment)")"
    return 1
  fi

  local target_disk=""
  read -r -p "$(__ "目标磁盘（默认: ${DISK_DEFAULT}）: " "Target disk (default: ${DISK_DEFAULT}): ")" input_disk || true
  target_disk="${input_disk:-$DISK_DEFAULT}"
  echo "$(__ "目标磁盘: " "Target disk: ")$target_disk"

  if ! confirm "$(__ "确认将对 $target_disk 执行操作并可能清除其上所有数据？（非常危险）" "Confirm operation on $target_disk - ALL data will be wiped? (VERY DANGEROUS)")"; then
    warn "$(__ "已取消" "Cancelled")"
    return 1
  fi

  if confirm "$(__ "是否用 cfdisk 手动分区（推荐）？" "Use cfdisk to manually partition (recommended)?")"; then
    echo "$(__ "请创建至少两个分区：EFI (~300M, type EFI) 和 Root (剩余空间)。完成后退出 cfdisk 继续。" "Create at least 2 partitions: EFI (~300M, type EFI) and Root (remaining space). Exit cfdisk to continue.")"
    cfdisk "$target_disk"
    if ! confirm "$(__ "继续进行格式化并安装？" "Proceed with formatting and installation?")"; then
      warn "$(__ "已取消" "Cancelled")"
      return 1
    fi
  else
    echo "$(__ "确保 $target_disk 已有合适分区：${target_disk}${EFI_PART} 和 ${target_disk}${ROOT_PART}" "Ensure $target_disk has proper partitions: ${target_disk}${EFI_PART} and ${target_disk}${ROOT_PART}")"
    if ! confirm "$(__ "继续（将格式化这些分区）？" "Continue (will format these partitions)?")"; then
      warn "$(__ "已取消" "Cancelled")"
      return 1
    fi
  fi

  local efi_dev="${target_disk}${EFI_PART}"
  local root_dev="${target_disk}${ROOT_PART}"

  echo "$(__ "EFI 分区: " "EFI partition: ")$efi_dev"
  echo "$(__ "Root 分区: " "Root partition: ")$root_dev"

  info "$(__ "格式化 EFI 分区为 FAT32 ..." "Formatting EFI partition as FAT32 ...")"
  mkfs.fat -F32 "$efi_dev"

  info "$(__ "格式化 Root 分区为 btrfs ..." "Formatting Root partition as btrfs ...")"
  mkfs.btrfs -f "$root_dev"

  info "$(__ "创建并挂载 btrfs 子卷 ..." "Creating and mounting btrfs subvolumes ...")"
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
    info "$(__ "使用 reflector 更新镜像源（中国优先）..." "Updating mirrors with reflector (China preferred)...")"
    reflector --verbose --country China --latest 15 --sort rate --save /etc/pacman.d/mirrorlist || true
  fi

  info "$(__ "选择内核 ..." "Selecting kernel ...")"
  local kernel_pkg=""
  read -r -p "$(__ "内核 (linux/linux-zen/linux-lts，默认 linux): " "Kernel (linux/linux-zen/linux-lts, default linux): ")" input_kernel || true
  input_kernel="${input_kernel:-linux}"
  case "$input_kernel" in
    linux|linux-zen|linux-lts) kernel_pkg="$input_kernel" ;;
    *) kernel_pkg="linux" ;;
  esac

  PKGS=(base "${kernel_pkg}" linux-firmware base-devel vim networkmanager intel-ucode grub efibootmgr btrfs-progs git reflector os-prober zram-generator)
  info "$(__ "开始 pacstrap 安装基础系统 ..." "Installing base system with pacstrap ...")"
  pacstrap /mnt ${PKGS[@]}

  info "$(__ "生成 fstab ..." "Generating fstab ...")"
  genfstab -U /mnt >> /mnt/etc/fstab

  C_HOSTNAME_PRE=$(__ "请输入主机名（默认: " "Enter hostname (default: ")
  C_HOSTNAME_SUF=$(__ "）: " "): ")
  C_PASSWD=$(__ "请为 root 用户设置密码：" "Set root password:")
  C_NO_UEFI=$(__ "未检测到 UEFI 环境，请根据需要手动安装 grub。" "UEFI not detected, install grub manually if needed.")
  C_CHROOT_DONE=$(__ "chroot 内部配置完成。" "chroot configuration complete.")

  cat > /mnt/root-setup.sh <<CHROOT_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
exec < /dev/tty

TIMEZONE="Asia/Shanghai"
LOCALES=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
HOSTNAME="archlinux"
ZRAM_SIZE_MB=4096

ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

for locale in "\${LOCALES[@]}"; do
  sed -i "s/^#\s\+\(\${locale}\)/\1/" /etc/locale.gen || true
done
locale-gen

cat > /etc/locale.conf <<EOF
LANG=en_US.UTF-8
EOF

read -r -p "${C_HOSTNAME_PRE}\${HOSTNAME}${C_HOSTNAME_SUF}" input_hostname || true
if [[ -n "\$input_hostname" ]]; then
  HOSTNAME="\$input_hostname"
fi
echo "\$HOSTNAME" > /etc/hostname

echo "${C_PASSWD}"
passwd root || true

if [ -d /sys/firmware/efi ]; then
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB || true
  grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "${C_NO_UEFI}"
fi

systemctl enable NetworkManager

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = \${ZRAM_SIZE_MB}
compression-algorithm = zstd
EOF

echo "${C_CHROOT_DONE}"
CHROOT_SCRIPT

  chmod +x /mnt/root-setup.sh
  info "$(__ "进入 chroot 执行配置 ..." "Entering chroot to run configuration ...")"
  arch-chroot /mnt /root-setup.sh || err "$(__ "arch-chroot 执行失败，请手动检查" "arch-chroot execution failed, please check manually")"

  log "$(__ "系统安装完成！请执行: umount -R /mnt && reboot" "System installation complete! Run: umount -R /mnt && reboot")"
}

# ===================== 初始化系统 (initialize-arch.sh) =====================

configure_repos() {
  info "$(__ "配置 multilib 仓库和 archlinuxcn 源 ..." "Configuring multilib repo and archlinuxcn source ...")"
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
  log "$(__ "仓库配置完成" "Repository configuration complete")"
}

install_btrfs_tools() {
  info "$(__ "安装 archlinuxcn-keyring ..." "Installing archlinuxcn-keyring ...")"
  pacman -Sy --noconfirm archlinuxcn-keyring
  info "$(__ "安装 btrfs 快照工具 ..." "Installing btrfs snapshot tools ...")"
  pacman -S --needed --noconfirm snapper snap-pac btrfs-progs btrfs-assistant grub-btrfs inotify-tools
  snapper -c root create-config /
  snapper -c home create-config /home
  systemctl enable --now grub-btrfsd
  log "$(__ "btrfs 快照工具安装配置完成" "btrfs snapshot tools installed and configured")"
}

install_lts_kernel() {
  info "$(__ "安装 linux-lts 内核 ..." "Installing linux-lts kernel ...")"
  pacman -S --noconfirm linux-lts
  snapper -c root create -d "Initial snapshot"
  snapper -c home create -d "Initial snapshot"
  grub-mkconfig -o /boot/grub/grub.cfg
  log "$(__ "linux-lts 内核及快照完成" "linux-lts kernel and snapshot complete")"
}

install_gpu_drivers() {
  info "$(__ "安装 NVIDIA 驱动 ..." "Installing NVIDIA drivers ...")"
  pacman -S --noconfirm linux-zen-headers linux-lts-headers nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils
  info "$(__ "安装 Intel 显卡驱动 ..." "Installing Intel GPU drivers ...")"
  pacman -S --needed --noconfirm mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  info "$(__ "安装视频编解码 ..." "Installing video codecs ...")"
  pacman -S --needed --noconfirm nvidia-utils libva-nvidia-driver intel-media-driver
  log "$(__ "显卡驱动安装完成" "GPU driver installation complete")"
}

install_multimedia() {
  info "$(__ "安装音视频服务 ..." "Installing audio/video services ...")"
  pacman -S --needed --noconfirm sof-firmware alsa-ucm-conf alsa-firmware pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack
  local user="${SUDO_USER:-$USER}"
  if id "$user" &>/dev/null; then
    su -c "systemctl --user enable --now pipewire pipewire-pulse wireplumber" "$user" 2>/dev/null || true
  fi
  info "$(__ "安装蓝牙服务 ..." "Installing Bluetooth ...")"
  pacman -S --needed --noconfirm bluez
  systemctl enable --now bluetooth
  log "$(__ "多媒体服务安装完成" "Multimedia services installation complete")"
}

install_fonts() {
  info "$(__ "安装字体 ..." "Installing fonts ...")"
  pacman -S --needed --noconfirm noto-fonts noto-fonts-emoji adobe-source-han-sans-cn-fonts
  log "$(__ "字体安装完成" "Fonts installation complete")"
}

install_flatpak() {
  info "$(__ "安装 flatpak ..." "Installing flatpak ...")"
  pacman -S --needed --noconfirm flatpak
  log "$(__ "flatpak 安装完成" "flatpak installation complete")"
}

install_yay() {
  info "$(__ "安装 yay (AUR 助手) ..." "Installing yay (AUR helper) ...")"
  pacman -S --needed yay
  log "$(__ "yay 安装完成" "yay installation complete")"
}

create_final_snapshot() {
  snapper -c root create -d "Initial archlinux done"
  snapper -c home create -d "Initial archlinux done"
  log "$(__ "最终快照已创建" "Final snapshot created")"
}

initialize_system() {
  echo
  warn "$(__ "========== 初始化系统（配置源、驱动、多媒体等） ==========" "========== Initialize System (repos, drivers, multimedia, etc.) ==========")"
  echo

  if [[ $EUID -ne 0 ]]; then
    err "$(__ "请以 root 权限运行" "Please run as root")"
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

  log "$(__ "系统初始化完成！建议重启。" "System initialization complete! Reboot recommended.")"
}

# ===================== 修复 NVIDIA 0x00000025 =====================

fix_nvidia_error() {
  echo
  warn "$(__ "========== 修复 NVIDIA 驱动 0x00000025 报错 ==========" "========== Fix NVIDIA driver error 0x00000025 ==========")"
  echo

  if [[ $EUID -ne 0 ]]; then
    err "$(__ "请以 root 权限运行" "Please run as root")"
    return 1
  fi

  info "$(__ "配置 /etc/modprobe.d/nvidia-open.conf ..." "Configuring /etc/modprobe.d/nvidia-open.conf ...")"
  cat > /etc/modprobe.d/nvidia-open.conf <<EOF
options nvidia NVreg_EnableGpuFirmware=1
options nvidia NVreg_EnableS0ixPowerManagement=0
options nvidia NVreg_RegistryDwords=EnableS0ixPowerManagement=0
options nvidia NVreg_InitializeSystemMemoryAllocations=1
options nvidia NVreg_UsePlatformInterface=1
EOF
  log "$(__ "nvidia-open.conf 配置完成" "nvidia-open.conf configured")"

  info "$(__ "修改内核引导参数 ..." "Modifying kernel boot parameters ...")"
  if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 acpi_enforce_resources=lax pcie_aspm=off"/' /etc/default/grub
  fi
  log "$(__ "内核引导参数已添加" "Kernel boot parameters added")"

  info "$(__ "重新编译 nvidia-open-dkms ..." "Rebuilding nvidia-open-dkms ...")"
  if command -v dkms &>/dev/null; then
    dkms autoinstall -k "$(uname -r)" 2>/dev/null || true
  fi
  pacman -S --noconfirm nvidia-open-dkms

  info "$(__ "更新 GRUB 和 initramfs ..." "Updating GRUB and initramfs ...")"
  grub-mkconfig -o /boot/grub/grub.cfg
  mkinitcpio -P

  log "$(__ "NVIDIA 驱动 0x00000025 修复完成！" "NVIDIA driver 0x00000025 fix complete!")"
  warn "$(__ "请执行 shutdown -h now 断电冷启动以使修复生效" "Run 'shutdown -h now' for a cold boot to apply the fix")"
}

# ===================== 主菜单 =====================

check_network() {
  if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    err "$(__ "网络连接异常，请确保设备已联网" "Network connection error, please ensure you are connected")"
    exit 1
  fi
}

show_menu() {
  tput reset 2>/dev/null || true
  echo "=============================================="
  echo "      $(__ "Arch Linux 安装与初始化集成脚本" "Arch Linux Installation & Initialization Script")"
  echo "=============================================="
  echo
  echo "  $(__ "1. 安装系统（分区/格式化/pacstrap/chroot）" "1. Install System (partition/format/pacstrap/chroot)")"
  echo "     $(__ "- 在 Arch live 环境中运行" "- Run in Arch live environment")"
  echo "  $(__ "2. 初始化系统（配置源/驱动/多媒体/字体等）" "2. Initialize System (repos/drivers/multimedia/fonts)")"
  echo "     $(__ "- 在已安装的 Arch 系统中运行" "- Run in installed Arch system")"
  echo "  $(__ "3. 修复 NVIDIA 驱动 0x00000025 报错" "3. Fix NVIDIA driver error 0x00000025")"
  echo "  $(__ "4. 重启系统" "4. Reboot")"
  echo "  $(__ "5. 关机（冷启动）" "5. Shutdown (cold boot)")"
  echo "  $(__ "0. 退出" "0. Exit")"
  echo
  echo "=============================================="
  echo
}

main() {
  while true; do
    show_menu
    read -rp "$(__ "请输入选项 [0-5]: " "Enter option [0-5]: ")" choice || true
    case $choice in
      1)
        install_system || true
        ;;
      2)
        initialize_system || true
        ;;
      3)
        fix_nvidia_error || true
        ;;
      4)
        reboot
        ;;
      5)
        shutdown -h now
        ;;
      0)
        info "$(__ "退出脚本" "Exiting script")"
        exit 0
        ;;
      *)
        warn "$(__ "无效选项，请重新输入" "Invalid option, please try again")"
        ;;
    esac
    echo
    read -rp "$(__ "按回车键返回主菜单..." "Press Enter to return to main menu...")" || true
  done
}

main "$@"
