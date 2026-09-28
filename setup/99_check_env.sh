#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 环境自检脚本
# =============================================================================
# 作用：全面检查 ROS 2 / 工作空间 / 串口 / ESP-IDF / 依赖包 是否就绪
# 用法：bash 99_check_env.sh
# 输出：逐项 PASS / WARN / FAIL，并在末尾给出汇总
# =============================================================================
set -uo pipefail

ROS_DISTRO_NAME="humble"
WS_DIR="${WS_DIR:-$HOME/leap_ros_ws}"
IDF_DIR="${IDF_DIR:-$HOME/esp/esp-idf}"

PASS=0; WARN=0; FAIL=0
ok()   { echo -e "  \033[1;32m[PASS]\033[0m $*"; PASS=$((PASS+1)); }
wn()   { echo -e "  \033[1;33m[WARN]\033[0m $*"; WARN=$((WARN+1)); }
no()   { echo -e "  \033[1;31m[FAIL]\033[0m $*"; FAIL=$((FAIL+1)); }
title(){ echo -e "\n\033[1;36m┌─ $* \033[0m"; }
has()  { command -v "$1" >/dev/null 2>&1; }
pkg()  { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

echo "=============================================================="
echo "  LEAP_ROS 机器人环境自检  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

# ---- 1. 系统 -----------------------------------------------------------------
title "1. 系统环境"
if [ "$(lsb_release -sc 2>/dev/null)" = "jammy" ]; then
  ok "Ubuntu $(lsb_release -ds 2>/dev/null)"
else
  wn "非 Ubuntu 22.04 (jammy)，ROS 2 Humble 官方支持该版本"
fi
ok "内核 $(uname -r) / 架构 $(dpkg --print-architecture)"
AVAIL=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${AVAIL:-0}" -gt 15 ] && ok "根分区可用 ${AVAIL}G" || wn "根分区可用仅 ${AVAIL}G，建议 >15G"

# ---- 2. ROS 2 -----------------------------------------------------------------
title "2. ROS 2 运行时"
if [ -f "/opt/ros/$ROS_DISTRO_NAME/setup.bash" ]; then
  ok "ROS 2 $ROS_DISTRO_NAME 已安装于 /opt/ros/$ROS_DISTRO_NAME"
  # 重要：ROS 的 setup.bash 直接引用未定义的 $AMENT_TRACE_SETUP_FILES，
  #       本脚本开了 set -u（nounset），source 会让自检在第 2 项直接中断。
  set +u
  # shellcheck disable=SC1090
  source "/opt/ros/$ROS_DISTRO_NAME/setup.bash" 2>/dev/null
  set -u
  ok "ros2 命令: $(ros2 --version 2>/dev/null | head -1 || echo 可用)"
  # 在 /tmp 下执行：colcon version-check 会在当前目录生成 log/，
  # 在 setup/ 里跑会把日志污染到脚本目录
  has colcon && ok "colcon: $(cd /tmp && colcon version-check 2>/dev/null | head -1 || echo 已安装)" \
             || no "colcon 未安装"
  has rosdep && ok "rosdep 已安装" || wn "rosdep 未安装"
else
  no "ROS 2 $ROS_DISTRO_NAME 未安装 → 执行 setup/01_install_ros2_humble.sh"
fi

# ---- 3. ROS 关键依赖包 --------------------------------------------------------
title "3. ROS 关键依赖包"
check_ros_pkg() {
  if pkg "ros-$ROS_DISTRO_NAME-$1"; then ok "ros-$ROS_DISTRO_NAME-$1"; else no "缺少 ros-$ROS_DISTRO_NAME-$1"; fi
}
check_ros_pkg desktop
check_ros_pkg navigation2
check_ros_pkg cartographer-ros
check_ros_pkg robot-localization
check_ros_pkg rmw-fastrtps-shared-cpp
check_ros_pkg micro-ros-msgs
check_ros_pkg tf2-ros
check_ros_pkg robot-state-publisher
check_ros_pkg joint-state-publisher

title "3.1 系统依赖包"
for p in python3-opencv python3-numpy python3-pil socat; do
  if pkg "$p"; then ok "$p"; else no "缺少 $p"; fi
done

# ---- 4. 工作空间 --------------------------------------------------------------
title "4. ROS 2 工作空间"
if [ -d "$WS_DIR/src" ]; then
  CNT=$(find "$WS_DIR/src" -name package.xml | wc -l)
  ok "工作空间 $WS_DIR（$CNT 个功能包）"
  if [ -f "$WS_DIR/install/setup.bash" ]; then
    ok "已编译（install/setup.bash 存在）"
    # 抽查关键可执行文件
    for exe in xuegecar_bringup micro_ros_agent; do
      if find "$WS_DIR/install" -name "$exe" -type f 2>/dev/null | grep -q .; then
        ok "可执行文件 $exe 已生成"
      else
        wn "未找到可执行文件 $exe"
      fi
    done
  else
    no "尚未编译 → 执行 setup/02_build_workspace.sh"
  fi
  # 缺少的官方包提示
  for p in leap_interfaces xuegecar_mavlink_bridge; do
    if [ -d "$WS_DIR/src/$p" ]; then ok "扩展包 $p 已部署"; else wn "未部署 $p（官方仓库新增包，非必需）"; fi
  done
else
  no "工作空间不存在: $WS_DIR/src"
fi

# ---- 5. 串口与设备 ------------------------------------------------------------
title "5. 串口与设备权限"
if id -nG "$USER" | grep -qw dialout; then
  ok "用户 $USER 已在 dialout 组（注意：需重新登录才进当前会话）"
else
  no "用户 $USER 不在 dialout 组 → sudo usermod -aG dialout $USER 后重新登录"
fi

# 组身份 ≠ 当前会话可访问，所以以「设备实际可读写」为权威判据
PORT_FOUND=0
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$dev" ] || continue
  PORT_FOUND=1
  VID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
  PID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
  PERM=$(stat -c '%U:%G %a' "$dev")
  if [ -r "$dev" ] && [ -w "$dev" ]; then
    ok "串口可用 $dev（$PERM，芯片 ${VID:-?}:${PID:-?}）"
  else
    no "串口不可读写 $dev（$PERM，芯片 ${VID:-?}:${PID:-?}）"
    echo "         本会话组: $(id -nG)"
    echo "         修复: sudo bash 11_fix_serial_perm.sh"
    if [ -n "$VID" ] && ! grep -qs "idVendor.*\"$VID\"" /etc/udev/rules.d/99-robot-serial.rules 2>/dev/null; then
      echo "         未在 udev 规则中看到 vendor ${VID}（可能与型号不匹配）"
    fi
  fi
done
if [ $PORT_FOUND -eq 0 ]; then
  wn "未检测到串口设备（未连接底盘/雷达时属正常）"
fi
if [ -f /etc/udev/rules.d/99-robot-serial.rules ]; then
  ok "串口 udev 规则已配置"
else
  wn "串口 udev 规则未配置（可选，建议配置）"
fi

# ---- 6. ESP-IDF ---------------------------------------------------------------
title "6. ESP-IDF 工具链"
if [ -f "$IDF_DIR/export.sh" ]; then
  ok "ESP-IDF 源码位于 $IDF_DIR"
  # 子模块完整性（关键：归档包会缺失）
  if [ -n "$(ls -A "$IDF_DIR/components/mqtt/esp-mqtt" 2>/dev/null)" ]; then
    ok "git 子模块完整（esp-mqtt 非空）"
  else
    no "git 子模块缺失（esp-mqtt 为空）→ cd $IDF_DIR && git submodule update --init --recursive"
  fi
  if [ -d "$HOME/.espressif/tools" ]; then
    ok "工具链已安装：$HOME/.espressif"
    if ls "$HOME/.espressif/python_env" >/dev/null 2>&1; then
      ok "ESP-IDF Python 虚拟环境已就绪"
    else
      wn "ESP-IDF Python 环境可能未就绪"
    fi
  else
    no "工具链未安装 → cd $IDF_DIR && ./install.sh esp32s3"
  fi
else
  no "ESP-IDF 未安装 → 执行 setup/03_install_espidf.sh"
fi

# ---- 6.1 固件工程 -------------------------------------------------------------
title "6.1 ESP32-S3 固件工程"
FW_ROOT="${FW_ROOT:-$HOME/leap_firmware}"
for proj in leap_low_v1 leap_cam; do
  if [ -f "$FW_ROOT/$proj/CMakeLists.txt" ]; then
    ok "固件工程 $proj 已部署"
    if [ -f "$FW_ROOT/$proj/build/merged-binary.bin" ]; then
      ok "  └ 已编译出 merged-binary.bin"
    else
      wn "  └ 尚未编译（cd $FW_ROOT/$proj && idf.py build）"
    fi
  else
    wn "固件工程 $proj 未部署（可选）"
  fi
done
# 检查 dependencies.lock 中 local 组件路径是否有效
# 注意：IDF 组件管理器每次构建会把 path 重写为「本机当前绝对路径」，
#       这本身是正常的；真正的问题只是路径指向别的机器（不存在）。
LOCK="$FW_ROOT/leap_low_v1/dependencies.lock"
if [ -f "$LOCK" ]; then
  LOCK_PATH=$(grep -E "^\s+path: " "$LOCK" 2>/dev/null | head -1 | sed -E 's/^\s+path: //')
  if [ -z "$LOCK_PATH" ]; then
    ok "dependencies.lock 无需修正"
  elif [ -d "$LOCK_PATH" ]; then
    ok "dependencies.lock 组件路径有效"
  else
    no "dependencies.lock 路径无效: $LOCK_PATH → 见 README Q11 修复"
  fi
fi

# ---- 7. 网络 ------------------------------------------------------------------
title "7. 网络连通性"
net_ok=0
if curl -sS -m 6 -o /dev/null "http://packages.ros.org/ros2/ubuntu/dists/jammy/Release" 2>/dev/null; then
  ok "packages.ros.org 可达"; net_ok=1
else
  wn "packages.ros.org 不可达"
fi
if curl -sS -m 6 -o /dev/null "https://dl.espressif.cn" 2>/dev/null; then
  ok "dl.espressif.cn（乐鑫国内镜像）可达"
else
  wn "dl.espressif.cn 不可达"
fi

# ---- 汇总 ---------------------------------------------------------------------
echo ""
echo "=============================================================="
echo -e "  自检汇总： \033[1;32mPASS $PASS\033[0m  \033[1;33mWARN $WARN\033[0m  \033[1;31mFAIL $FAIL\033[0m"
echo "=============================================================="
if [ $FAIL -gt 0 ]; then
  echo "存在 FAIL 项，请按上面提示修复后重新自检。"
  exit 1
elif [ $WARN -gt 0 ]; then
  echo "基本就绪（WARN 项不影响核心功能）。"
  exit 0
else
  echo "环境完全就绪，可以开始使用机器人！"
  exit 0
fi
