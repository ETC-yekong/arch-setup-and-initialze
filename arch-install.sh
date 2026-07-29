#!/usr/bin/env bash
# arch-install.sh
# 基于现有 arch 安装步骤的交互式安装脚本（参考 arch安装.sh）
# 注意：这是一个破坏性脚本，会格式化磁盘。仅在 Arch live 环境且确认目标磁盘后运行。

set -euo pipefail
IFS=$'\n\t'

# 可配置项（运行时可覆盖）
DISK_DEFAULT="/dev/nvme0n1"
EFI_PART="p1"
ROOT_PART="p2"
KERNEL_PKG="linux"
# 命令行开关 --kernel=<name> 支持指定内核包名，例如: --kernel=linux-zen
# 或使用 --kernel=prompt 在安装内核那一步进行交互选择
KERNEL_SELECTION="${KERNEL_PKG}"
USE_ZEN=false
BTRFS_SUBVOL_ROOT="@"
BTRFS_SUBVOL_HOME="@home"
ZRAM_SIZE_MB=4096
TIMEZONE="Asia/Shanghai"
LOCALES=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
HOSTNAME_DEFAULT="archlinux"

function echo_err() { echo "$@" >&2; }

function require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo_err "此脚本必须以 root 身份运行（在 Arch live 环境中）。"
    exit 1
  fi
}

function confirm() {
  local msg="$1"
  read -r -p "$msg [y/N]: " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

function usage() {
  cat <<EOF
用法: $0 [目标磁盘]
示例: $0 /dev/nvme0n1
说明: 脚本会执行分区/格式化/挂载/安装基系统并生成 chroot 配置脚本。强烈建议先备份数据并手动检查分区布局。
EOF
}

# 解析命令行参数：支持 --kernel=<name> 和位置参数为目标磁盘
if [[ "$#" -gt 0 ]]; then
  : # proceed to parsing
fi
POSITIONAL=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --kernel=*)
      KERNEL_SELECTION="${1#*=}"
      shift
      ;;
    --kernel)
      KERNEL_SELECTION="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      echo_err "未知选项: $1"
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

# 恢复位置参数（第一个位置参数将作为目标磁盘）
set -- "${POSITIONAL[@]}"
TARGET_DISK="${1-:$DISK_DEFAULT}"

require_root

echo "目标磁盘: $TARGET_DISK"

if ! confirm "确认将对 $TARGET_DISK 执行操作并可能清除其上所有数据？（非常危险）"; then
  echo "已取消。"
  exit 0
fi

# 分区提示 — 交互或自动
if confirm "是否用 cfdisk 手动分区（推荐）？"; then
  echo "正在打开 cfdisk，请创建至少两个分区：EFI (~300M, type EFI) 和 Root (剩余空间)。完成后退出 cfdisk 继续。"
  cfdisk "$TARGET_DISK"
  echo "请确认分区已创建，然后继续。"
  if ! confirm "继续进行格式化并安装？"; then
    echo "已取消。"
    exit 0
  fi
else
  echo "跳过手动分区。确保 $TARGET_DISK 已有合适的分区表和分区：${TARGET_DISK}${EFI_PART} 和 ${TARGET_DISK}${ROOT_PART}。"
  if ! confirm "继续（将格式化这些分区）？"; then
    echo "已取消。"
    exit 0
  fi
fi

EFI_DEVICE="${TARGET_DISK}${EFI_PART}"
ROOT_DEVICE="${TARGET_DISK}${ROOT_PART}"

echo "EFI 分区: $EFI_DEVICE"
echo "Root 分区: $ROOT_DEVICE"

# 格式化分区
echo "格式化 EFI 分区为 FAT32..."
mkfs.fat -F32 "$EFI_DEVICE"

echo "格式化 Root 分区为 btrfs..."
mkfs.btrfs -f "$ROOT_DEVICE"

# 创建并挂载 btrfs 子卷
echo "挂载并创建 btrfs 子卷..."
mount -t btrfs "$ROOT_DEVICE" /mnt
btrfs subvolume create /mnt/${BTRFS_SUBVOL_ROOT}
btrfs subvolume create /mnt/${BTRFS_SUBVOL_HOME}
umount /mnt

echo "用 subvolume=@,compress=zstd 挂载 Root 子卷..."
mount -t btrfs -o subvol=${BTRFS_SUBVOL_ROOT},compress=zstd "$ROOT_DEVICE" /mnt
mkdir -p /mnt/home
mount -t btrfs -o subvol=${BTRFS_SUBVOL_HOME},compress=zstd "$ROOT_DEVICE" /mnt/home

mkdir -p /mnt/efi
mount --mkdir "$EFI_DEVICE" /mnt/efi

# 更新镜像源（需要 reflector 已安装在 live 环境）
if command -v reflector >/dev/null 2>&1; then
  echo "使用 reflector 更新 /etc/pacman.d/mirrorlist（中国镜像优先）..."
  reflector --verbose --country China --latest 15 --sort rate --save /etc/pacman.d/mirrorlist || true
else
  echo "reflector 未安装，跳过自动更新镜像源。"
fi

# 安装基础系统
echo "开始 pacstrap 安装基础系统（可能需要联网）..."

# 根据命令行开关或交互选择内核包
if [[ "${KERNEL_SELECTION}" == "prompt" || "${KERNEL_SELECTION}" == "ask" ]]; then
  echo "请选择要安装的内核："
  PS3="输入编号并回车: "
  select k in "linux" "linux-zen" "linux-lts" "自定义（输入包名）"; do
    case "$k" in
      linux)
        KERNEL_PACKAGE="linux"; break;;
      linux-zen)
        KERNEL_PACKAGE="linux-zen"; break;;
      linux-lts)
        KERNEL_PACKAGE="linux-lts"; break;;
      "自定义（输入包名）")
        read -r -p "输入自定义内核包名: " custom_kernel
        KERNEL_PACKAGE="$custom_kernel"
        break
        ;;
      *)
        echo "无效选择，请重试。"
        ;;
    esac
done
else
  # 非交互模式：使用用户指定的 KERNEL_SELECTION，如果留空则使用默认 KERNEL_PKG
  if [[ -n "${KERNEL_SELECTION-}" ]]; then
    KERNEL_PACKAGE="${KERNEL_SELECTION}"
  else
    KERNEL_PACKAGE="${KERNEL_PKG}"
  fi
fi

# 软件包清单，基于参考文件并做了少量修正
PKGS=(base "${KERNEL_PACKAGE}" linux-firmware base-devel vim networkmanager intel-ucode grub efibootmgr btrfs-progs git reflector os-prober zram-generator)

pacstrap /mnt ${PKGS[@]}

# 生成 fstab
echo "生成 /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 生成 chroot 脚本，自动执行一组初始化任务
cat > /mnt/root-setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# 在 chroot 内运行的初始化脚本
TIMEZONE="Asia/Shanghai"
LOCALES=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8")
HOSTNAME="archlinux"
ZRAM_SIZE_MB=4096

# 时区
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# 语言
for l in "${LOCALES[@]}"; do
  grep -q "^#?${l}" /etc/locale.gen || true
done
# 确保 locale.gen 包含需要的 locale
# 这里采用简单替换方式：取消对应行注释
for locale in "${LOCALES[@]}"; do
  sed -i "s/^#\s\+\(${locale}\)/\1/" /etc/locale.gen || true
done
locale-gen

# 写入 /etc/locale.conf
cat > /etc/locale.conf <<EOF
LANG=en_US.UTF-8
EOF

# 主机名
read -r -p "请输入主机名（默认: ${HOSTNAME}）: " input_hostname || true
if [[ -n "$input_hostname" ]]; then
  HOSTNAME="$input_hostname"
fi
echo "$HOSTNAME" > /etc/hostname

# root 密码（交互）
echo "请为 root 用户设置密码："
passwd root

# 安装并配置 grub（EFI）
if [ -d /sys/firmware/efi ]; then
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB || true
  grub-mkconfig -o /boot/grub/grub.cfg
else
  echo "未检测到 UEFI 环境，请根据需要安装 grub 到 BIOS/legacy 模式。"
fi

# 启用 NetworkManager
systemctl enable NetworkManager

# 配置 zram-generator
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
EOF

# 完成提示
echo "chroot 内部配置完成。请在首次启动后根据需要调整 /etc/locale.conf、/etc/hostname、/etc/default/grub 等配置，然后重建 grub 配置并重启。"
CHROOT_SCRIPT

# 使脚本可执行
chmod +x /mnt/root-setup.sh

# 进入 chroot 并运行脚本
echo "进入 chroot 并执行 /root-setup.sh（在 chroot 内会询问 root 密码等交互操作）..."
arch-chroot /mnt /root-setup.sh || echo "arch-chroot 执行失败，请手动进入 /mnt 并检查 /root-setup.sh"

echo "安装脚本执行完毕。请卸载 /mnt 并重启系统：exit && reboot"

# 结束
