# Arch Linux 安装与初始化集成脚本

将 **安装系统** 和 **初始化系统** 整合为一个交互式脚本，方便分步执行。

## 注意事项 / 免责声明

- **该脚本包含格式化磁盘、修改系统配置等高风险操作，使用不当可能导致数据丢失**
- 使用前请仔细阅读脚本内容，确保理解每一步的作用
- 建议先在虚拟机或备用机器上测试
- 作者不对因使用本脚本造成的任何直接或间接损失承担责任
- 使用本脚本即表示你已了解并承担所有风险

## 从 GitHub 获取并运行

```bash
git clone https://github.com/<你的用户名>/<仓库名>.git
cd <仓库名>
sudo bash arch-install-and-initialize.sh
```

## 主菜单选项

### 1. 安装系统
- **运行环境**: Arch live 环境
- **功能**: 分区 → 格式化 → 创建 btrfs 子卷 → pacstrap 基础系统 → chroot 配置（时区/语言/主机名/root密码/GRUB/NetworkManager/zram-generator）
- **注意**: 破坏性操作，会格式化目标磁盘，请提前备份数据

### 2. 初始化系统
- **运行环境**: 已安装的 Arch 系统（首次启动后）
- **功能**:
  - 启用 multilib 仓库和 archlinuxcn 源
  - 安装 yay（AUR 助手）
  - 安装 btrfs 快照工具（snapper + grub-btrfs）
  - 安装 linux-lts 内核
  - 安装 NVIDIA + Intel 显卡驱动及视频编解码
  - 安装音视频服务（PipeWire）和蓝牙服务
  - 安装字体（Noto、思源黑体）
  - 安装 Flatpak
  - 创建 snapper 快照

### 3. 修复 NVIDIA 驱动 0x00000025 报错
- **运行环境**: 已安装的 Arch 系统
- **功能**: 配置内核模块参数 → 修改 GRUB 引导参数 → 重新编译 nvidia-open-dkms → 更新 GRUB 和 initramfs
- **注意**: 修复完成后需 `shutdown -h now` 断电冷启动

## 流程建议

```
Arch live 环境
  └── 选项 1: 安装系统
       └── reboot 进入新系统
            └── 选项 2: 初始化系统
                 └── (可选) 选项 3: 修复 NVIDIA 驱动
                      └── shutdown -h now 冷启动
```
