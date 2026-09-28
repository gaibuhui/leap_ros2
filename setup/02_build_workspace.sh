#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— ROS 2 工作空间构建脚本
# =============================================================================
# 作用：编译 ~/leap_ros_ws 下的全部 ROS 2 功能包
# 前置：已执行 01_install_ros2_humble.sh 并安装好 ROS 2 Humble
# 用法：bash 02_build_workspace.sh [--clean]
#   --clean  编译前删除 build/ install/ log/（全量重编）
# =============================================================================
set -euo pipefail

WS_DIR="${WS_DIR:-$HOME/leap_ros_ws}"
ROS_DISTRO_NAME="humble"
JOBS="${JOBS:-$(nproc)}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

# ---- 1. 校验 ROS 环境 -------------------------------------------------------
step "1/4 校验 ROS 2 环境"
if [ ! -f "/opt/ros/$ROS_DISTRO_NAME/setup.bash" ]; then
  error "未找到 /opt/ros/$ROS_DISTRO_NAME/setup.bash"
  error "请先执行: bash 01_install_ros2_humble.sh"
  exit 1
fi
# 重要：ROS 的 setup.bash 内部直接引用了未定义的 $AMENT_TRACE_SETUP_FILES，
#       本脚本开启了 set -u（nounset），一旦 source 就会立即终止整个脚本（exit 127）。
#       所以 source 前后必须临时关闭 nounset。
set +u
# shellcheck disable=SC1090
source "/opt/ros/$ROS_DISTRO_NAME/setup.bash"
set -u
info "ROS 2 已加载: $(ros2 --version 2>/dev/null || echo "$ROS_DISTRO_NAME")"

# ---- 1.1 确保使用系统 Python -------------------------------------------------
# ament 的 package_xml_2_cmake.py 依赖 catkin_pkg，而 catkin_pkg 只装在 ROS 2
# Humble 绑定的系统 Python（/usr/bin/python3 = 3.10）里。若 PATH 中 python3 被
# conda / 独立 Python 抢占，构建会在解析 package.xml 时报：
#   ModuleNotFoundError: No module named 'catkin_pkg'
if ! python3 -c "import catkin_pkg" >/dev/null 2>&1; then
  if /usr/bin/python3 -c "import catkin_pkg" >/dev/null 2>&1; then
    warn "当前 python3 ($(command -v python3)) 缺少 catkin_pkg，构建改用 /usr/bin/python3"
    export PATH="/usr/bin:/bin:$PATH"
  else
    error "系统 Python 缺少 catkin_pkg"
    error "修复: sudo apt install -y python3-catkin-pkg-modules python3-empy"
    exit 1
  fi
fi
info "python3: $(command -v python3) ($(python3 -V 2>&1))"

# 额外把 Python 路径显式传给 CMake：仅靠 PATH 不够，因为 CMake 会把上次
# 构建用到的解释器路径缓存进 CMakeCache.txt 并在后续配置中继续复用。
CMAKE_EXTRA=()
if [ "$(command -v python3)" != "/usr/bin/python3" ]; then
  CMAKE_EXTRA+=(-DPython3_EXECUTABLE=/usr/bin/python3 -DPYTHON_EXECUTABLE=/usr/bin/python3)
fi

# ---- 1.2 定位 YDLidar-SDK ---------------------------------------------------
# ydlidar_ros2_driver 通过 find_package(ydlidar_sdk REQUIRED) 引用该库；
# 该库不在 apt 源里，需先执行 08_install_ydlidar_sdk.sh 编译安装。
YDLIDAR_PREFIX=""
for p in "$HOME/.local" /usr/local /opt/ydlidar_sdk; do
  if [ -e "$p/lib/cmake/ydlidar_sdk/ydlidar_sdkConfig.cmake" ] \
     || [ -e "$p/share/ydlidar_sdk/cmake/ydlidar_sdkConfig.cmake" ]; then
    YDLIDAR_PREFIX="$p"
    break
  fi
done
if [ -n "$YDLIDAR_PREFIX" ]; then
  info "YDLidar-SDK: $YDLIDAR_PREFIX"
  CMAKE_EXTRA+=(-DCMAKE_PREFIX_PATH="$YDLIDAR_PREFIX")
  if [ "$YDLIDAR_PREFIX" != "/usr/local" ]; then
    # YDLidar-SDK 生成的 ydlidar_sdkConfig.cmake 中 YDLIDAR_SDK_LIBRARY_DIRS 为空，
    # 驱动仅靠 link_directories() 拿不到库目录，链接阶段报「找不到 -lydlidar_sdk」。
    # /usr/local/lib 属于链接器默认搜索路径，所以系统安装没这个问题；
    # 装在非系统前缀时必须补上库目录。
    export LIBRARY_PATH="$YDLIDAR_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    info "已补充库搜索路径: LIBRARY_PATH=$LIBRARY_PATH"
  fi
else
  warn "未找到 YDLidar-SDK → ydlidar_ros2_driver 会编译失败"
  warn "修复: bash setup/08_install_ydlidar_sdk.sh"
fi

# ---- 2. 校验工作空间 --------------------------------------------------------
step "2/4 校验工作空间"
if [ ! -d "$WS_DIR/src" ]; then
  error "工作空间不存在: $WS_DIR/src"
  error "请先部署源码到 $WS_DIR/src"
  exit 1
fi
PKG_COUNT=$(find "$WS_DIR/src" -name package.xml | wc -l)
info "工作空间: $WS_DIR"
info "检测到 $PKG_COUNT 个功能包"
find "$WS_DIR/src" -maxdepth 2 -name package.xml -printf "    - %h\n" | sed "s|$WS_DIR/src/||"

# ---- 3. 清理（可选） --------------------------------------------------------
if [ "${1:-}" = "--clean" ]; then
  step "3/4 清理旧构建产物"
  rm -rf "$WS_DIR/build" "$WS_DIR/install" "$WS_DIR/log"
  info "已清理 build/ install/ log/"
else
  step "3/4 增量编译（如需全量重编请加 --clean）"
fi

# ---- 4. 编译 ----------------------------------------------------------------
step "4/4 开始编译（并行度 $JOBS）"
cd "$WS_DIR"
set +e
colcon build \
  --symlink-install \
  --parallel-workers "$JOBS" \
  --cmake-args -DCMAKE_BUILD_TYPE=Release "${CMAKE_EXTRA[@]}" \
  --event-handlers console_direct+
BUILD_RC=$?
set -e

echo ""
if [ $BUILD_RC -eq 0 ]; then
  info "=================================================================="
  info "编译成功！"
  info "=================================================================="
  echo "加载工作空间:"
  echo "    source $WS_DIR/install/setup.bash"
  echo ""
  echo "启动整机（雷达 + micro-ROS + 底盘）:"
  echo "    ros2 launch xuegeros_demo bringup_all.launch.py"
  echo "=================================================================="
else
  error "编译失败（退出码 $BUILD_RC）"
  echo "查看失败包:  cat $WS_DIR/log/latest_build/events.log"
  echo "单独重编:    colcon build --packages-select <包名> --event-handlers console_direct+"
  exit $BUILD_RC
fi
