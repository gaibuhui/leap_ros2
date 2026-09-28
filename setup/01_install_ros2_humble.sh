#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS / 学哥ROS 机器人 —— ROS 2 Humble 环境安装脚本（需 sudo）
# =============================================================================
# 作用：安装 ROS 2 Humble 桌面版 + 机器人所需全部依赖 + micro-ROS 相关组件
# 适用：Ubuntu 22.04 (jammy) x86_64
# 用法：bash 01_install_ros2_humble.sh
# 说明：本脚本会修改系统，全程需要 sudo 权限。预计下载 1.5~2.5 GB。
# =============================================================================
set -euo pipefail

ROS_DISTRO_NAME="humble"
ROS_APT_SOURCE="http://packages.ros.org/ros2/ubuntu"
KEYRING="/usr/share/keyrings/ros-archive-keyring.gpg"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"

# ---- 辅助函数 ---------------------------------------------------------------
info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

# 统一 sudo（支持脚本内已被认证过的情况）
run_sudo() {
  if [ -n "$SUDO_PASSWORD" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

# ---- 0. 环境校验 -------------------------------------------------------------
step "0/8 环境校验"
if [ "$(lsb_release -sc 2>/dev/null)" != "jammy" ]; then
  error "本脚本仅适用于 Ubuntu 22.04 (jammy)，当前为: $(lsb_release -sc 2>/dev/null || echo unknown)"
  exit 1
fi
info "系统: $(lsb_release -ds)"
info "架构: $(dpkg --print-architecture)"

# ---- 1. 启用 UTF-8 locale ----------------------------------------------------
step "1/8 配置 UTF-8 locale"
run_sudo apt-get update -qq
run_sudo apt-get install -y -qq locales
run_sudo locale-gen en_US en_US.UTF-8
run_sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
info "locale 已配置"

# ---- 2. 配置 ROS 2 apt 源（幂等） --------------------------------------------
step "2/8 配置 ROS 2 apt 源"
run_sudo apt-get install -y -qq software-properties-common curl gnupg lsb-release
if [ ! -f "$KEYRING" ]; then
  info "导入 ROS 2 GPG key..."
  curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /tmp/ros.key 2>/dev/null || \
    curl -sSL https://gitee.com/mirrors/rosdistro/raw/master/ros.key -o /tmp/ros.key
  run_sudo cp /tmp/ros.key "$KEYRING"
  run_sudo chmod 644 "$KEYRING"
fi

# 国内网络优先用清华 TUNA 镜像；如需官方源请把 MIRROR 改为 packages.ros.org
MIRROR="${ROS_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING] $MIRROR jammy main" \
  | run_sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null
info "ROS 2 源: $MIRROR"

# ---- 3. 安装基础开发工具 -----------------------------------------------------
step "3/8 安装基础开发工具"
run_sudo apt-get update -qq
run_sudo apt-get install -y -qq \
  build-essential cmake git wget curl unzip \
  python3-pip python3-venv python3-dev python3-setuptools \
  socat can-utils usbutils udev

# ---- 4. 安装 ROS 2 Humble ----------------------------------------------------
step "4/8 安装 ROS 2 Humble 桌面版（下载量较大，请耐心等待）"
run_sudo apt-get install -y ros-humble-desktop
info "ros-humble-desktop 安装完成"

# ---- 5. 安装机器人功能依赖 ---------------------------------------------------
step "5/8 安装机器人功能依赖"
run_sudo apt-get install -y \
  python3-colcon-common-extensions \
  python3-rosdep python3-vcstool \
  python3-opencv python3-numpy python3-pil \
  ros-humble-ros-base \
  ros-humble-navigation2 ros-humble-nav2-bringup \
  ros-humble-cartographer ros-humble-cartographer-ros \
  ros-humble-robot-localization \
  ros-humble-slam-toolbox \
  ros-humble-robot-state-publisher \
  ros-humble-joint-state-publisher \
  ros-humble-xacro \
  ros-humble-tf2 ros-humble-tf2-ros ros-humble-tf2-tools ros-humble-tf2-geometry-msgs \
  ros-humble-message-filters \
  ros-humble-lifecycle-msgs \
  ros-humble-cv-bridge \
  ros-humble-image-transport \
  ros-humble-qt-gui-cpp libqt5widgets5 \
  ros-humble-teleop-twist-keyboard \
  ros-humble-rviz2 ros-humble-rqt \
  ros-humble-rmw-fastrtps-shared-cpp \
  ros-humble-rmw-dds-common \
  ros-humble-micro-ros-msgs \
  ros-humble-rosidl-default-generators \
  ros-humble-diagnostic-updater
info "功能依赖安装完成"

# ---- 6. 初始化 rosdep -------------------------------------------------------
step "6/8 初始化 rosdep"
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
  run_sudo rosdep init || warn "rosdep init 已执行过或失败"
fi
rosdep update --rosdistro humble || warn "rosdep update 失败（可稍后手动重试）"

# ---- 7. 串口权限与 udev 规则 ------------------------------------------------
step "7/8 配置串口权限与 udev 规则"
run_sudo usermod -aG dialout "$USER"
info "用户 $USER 已加入 dialout 组"

# micro-ROS / ESP32-S3 通过 USB 串口或 UDP；这里给常见 USB 转串口设备固定权限
# 注意：QinHeng 1a86 有多个 product id —— CH340 常见 7523，但存在上报 7522 的批次，
#       只写 idProduct=="7523" 会漏掉这类设备（表现为串口权限停在 660 打不开）。
#       故 1a86 按 vendor 通配。TAG+="uaccess" 让当前登录用户免重登即可访问。
run_sudo tee /etc/udev/rules.d/99-robot-serial.rules >/dev/null <<'EOF'
# LEAP_ROS 机器人串口设备权限
# CH340/CH341 (多数国产 ESP32 开发板) —— 按 vendor 通配，覆盖 7522/7523 等
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0666", GROUP="dialout", TAG+="uaccess"
# CP210x (Silicon Labs)
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666", GROUP="dialout", TAG+="uaccess"
# ESP32-S3 原生 USB-CDC / JTAG
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0666", GROUP="dialout", TAG+="uaccess"
# FTDI
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666", GROUP="dialout", TAG+="uaccess"
EOF
run_sudo udevadm control --reload-rules
run_sudo udevadm trigger
info "udev 规则已写入 /etc/udev/rules.d/99-robot-serial.rules"
# 已插入的设备需要重新触发才生效；引导用户做一次
info "若 /dev/ttyUSB* 权限仍为 660，请拔插一次 USB 线（或让系统重新枚举该设备）"
warn "dialout 组权限需重新登录才生效；或执行 newgrp dialout。装完 udev 规则后通常已无需此步"

# ---- 8. 配置环境变量 --------------------------------------------------------
step "8/8 配置 shell 环境变量"
ROS_SETUP_LINE="source /opt/ros/humble/setup.bash"
WS_SETUP_LINE="[ -f \$HOME/leap_ros_ws/install/setup.bash ] && source \$HOME/leap_ros_ws/install/setup.bash"
if ! grep -qF "/opt/ros/humble/setup.bash" "$HOME/.bashrc"; then
  {
    echo ""
    echo "# >>> ROS 2 Humble (LEAP_ROS) >>>"
    echo "$ROS_SETUP_LINE"
    echo "$WS_SETUP_LINE"
    echo "export ROS_DOMAIN_ID=0"
    echo "export RMW_IMPLEMENTATION=rmw_fastrtps_cpp"
    echo "export RCUTILS_LOGGING_BUFFERED_STREAM=1"
    echo "export ROSDISTRO_INDEX_URL=$ROS_REPO/index-v4.yaml"
    echo "# <<< ROS 2 Humble (LEAP_ROS) <<<"
  } >> "$HOME/.bashrc"
  info "已向 ~/.bashrc 追加 ROS 2 环境变量"
else
  info "~/.bashrc 已包含 ROS 2 配置，跳过"
fi

echo ""
echo "=================================================================="
info "ROS 2 Humble 安装完成！"
echo "=================================================================="
echo "后续步骤："
echo "  1) 重新登录或执行: newgrp dialout   （使串口权限生效）"
echo "  2) 打开新终端，验证: ros2 --version"
echo "  3) 构建工作空间: bash 02_build_workspace.sh"
echo "  4) 运行自检:     bash 99_check_env.sh"
echo "=================================================================="
