#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— YDLidar-SDK 编译安装脚本
# =============================================================================
# 作用：编译安装 YDLidar-SDK 库
# 原因：`ydlidar_ros2_driver` 在 CMakeLists.txt 里有
#           find_package(ydlidar_sdk REQUIRED)
#       而 YDLidar-SDK **不在 ROS apt 源里**，必须单独从源码编译安装。
#       缺失时 colcon build 会报：
#           Could not find a package configuration file provided by "ydlidar_sdk"
# 用法：
#   bash 08_install_ydlidar_sdk.sh              # 装到 ~/.local（无需 sudo）
#   bash 08_install_ydlidar_sdk.sh --system     # 装到 /usr/local（需 sudo，官方做法）
#   PREFIX=/opt/ydlidar bash 08_install_ydlidar_sdk.sh
# 说明：装到 ~/.local 时，02_build_workspace.sh 会自动探测并传入 CMAKE_PREFIX_PATH。
# =============================================================================
set -euo pipefail

SDK_DIR="${SDK_DIR:-$HOME/ydlidar_sdk}"
INSTALL_PREFIX="${PREFIX:-$HOME/.local}"
USE_SUDO=0

for arg in "$@"; do
  case "$arg" in
    --system) INSTALL_PREFIX="/usr/local"; USE_SUDO=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg（可用: --system）"; exit 2 ;;
  esac
done

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

run_sudo() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

# ---- 1. 获取源码 -------------------------------------------------------------
step "1/4 获取 YDLidar-SDK 源码"
# 注意：YDLidar-SDK 没有 humble 分支，直接用 master（同时兼容 Humble）
if [ -f "$SDK_DIR/CMakeLists.txt" ]; then
  info "已存在源码: $SDK_DIR（跳过下载）"
else
  if [ -d "$SDK_DIR" ]; then
    warn "$SDK_DIR 存在但不完整，将重新下载"
  fi
  info "从 GitHub 克隆（约 16 MB）..."
  # 说明：gitee 上暂无可靠镜像（git ls-remote 会要求登录），因此走 GitHub。
  #       若直连缓慢，可先开启本地代理：export https_proxy=http://127.0.0.1:7890
  git clone --depth 1 https://github.com/YDLIDAR/YDLidar-SDK.git "$SDK_DIR" \
    || { error "克隆失败，请检查网络或配置代理后重试"; exit 1; }
fi
info "源码: $SDK_DIR"

# ---- 2. 编译 -----------------------------------------------------------------
step "2/4 配置与编译（安装前缀: $INSTALL_PREFIX）"
BUILD_DIR="$SDK_DIR/build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
# cmake_minimum_required(2.8) 在 CMake >= 3.27 上会有兼容性报错，这里放宽策略
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -j"$(nproc)"
info "编译完成"

# ---- 3. 安装 -----------------------------------------------------------------
step "3/4 安装"
if [ "$USE_SUDO" -eq 1 ]; then
  info "安装到 $INSTALL_PREFIX（需要 sudo）"
  run_sudo make install
  run_sudo ldconfig || true
else
  info "安装到 $INSTALL_PREFIX（用户目录，无需 sudo）"
  make install
fi

# ---- 4. 验证 -----------------------------------------------------------------
step "4/4 验证安装结果"
CONFIG_OK=0
for c in "$INSTALL_PREFIX/lib/cmake/ydlidar_sdk/ydlidar_sdkConfig.cmake" \
         "$INSTALL_PREFIX/share/ydlidar_sdk/cmake/ydlidar_sdkConfig.cmake"; do
  if [ -f "$c" ]; then
    info "CMake 配置: $c"
    CONFIG_OK=1
    break
  fi
done
if [ "$CONFIG_OK" -eq 0 ]; then
  error "未找到 ydlidar_sdkConfig.cmake，安装可能失败"
  exit 1
fi

echo ""
echo "=================================================================="
info "YDLidar-SDK 安装完成"
echo "=================================================================="
if [ "$INSTALL_PREFIX" = "/usr/local" ]; then
  echo "已装到系统路径，colcon build 可直接找到，无需额外配置。"
else
  echo "已装到用户路径 $INSTALL_PREFIX。"
  echo "02_build_workspace.sh 会自动探测该前缀并传入 CMAKE_PREFIX_PATH，"
  echo "直接执行即可："
  echo "    bash 02_build_workspace.sh"
  echo ""
  echo "若要在其它 CMake 工程中手动使用："
  echo "    cmake .. -DCMAKE_PREFIX_PATH=$INSTALL_PREFIX"
fi
echo "=================================================================="
