#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— ESP32-S3 固件编译与烧录脚本
# =============================================================================
# 作用：一键编译并烧录下位机固件（leap_low_v1）或 WiFi 图传固件（leap_cam）
#
# 用法（两种写法等价，位置参数是简写）：
#   bash 04_flash_firmware.sh low                    # 烧主控固件（自动探测串口）
#   bash 04_flash_firmware.sh cam                    # 烧图传固件
#   bash 04_flash_firmware.sh --port /dev/ttyUSB0    # 指定串口
#   bash 04_flash_firmware.sh low --port /dev/ttyUSB0 --monitor
#   bash 04_flash_firmware.sh --list                 # 列出可用串口
#   bash 04_flash_firmware.sh low --build-only       # 只编译不烧录
#
# 串口名：ESP32-S3 原生 USB-CDC 多为 /dev/ttyACM0；
#         CH340/CP210x 转串口芯片多为 /dev/ttyUSB0（用 --list 或 ls /dev/ttyUSB* 确认）
#
# 前置：已执行 03_install_espidf.sh
# =============================================================================
set -euo pipefail

IDF_DIR="${IDF_DIR:-$HOME/esp/esp-idf}"
TARGET="esp32s3"
BAUD="${BAUD:-460800}"

# 固件工程目录（来自 1.源码/）
SRC_ROOT="${SRC_ROOT:-/media/lixin/新加卷/robot/1.源码}"
PROJ_MCU_FALLBACK="$HOME/leap_firmware/leap_low_v1"
PROJ_CAM_FALLBACK="$HOME/leap_firmware/leap_cam"

PORT=""
PROJECT="mcu"   # mcu | cam
DO_MONITOR=0
BUILD_ONLY=0

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

# 兜底：set -e 触发的静默退出往往「什么都不打印」，很难查。
# 这里捕获 ERR，打出行号与出错命令。仅在被 set -e 终止时触发，
# 不影响 if / || / && 里被显式处理的失败。
trap 'rc=$?; if [ "$rc" -ne 0 ]; then error "脚本在第 $LINENO 行失败（退出码 $rc）：$BASH_COMMAND"; fi' ERR

usage() {
  # 打印文件头部的注释块作为帮助（自动适应行数变化）
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  exit 0
}

list_ports() {
  echo "=== 可用串口设备 ==="
  local n=0
  for d in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$d" ] || continue
    n=$((n+1))
    local vid pid acc
    vid=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
    pid=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
    if [ -r "$d" ] && [ -w "$d" ]; then acc="可读写 ✅"; else acc="不可读写 ❌（sudo bash 11_fix_serial_perm.sh）"; fi
    printf '  %s  %s  芯片=%s:%s  %s\n' "$d" "$(stat -c '%U:%G %a' "$d")" "${vid:-?}" "${pid:-?}" "$acc"
  done
  [ "$n" -eq 0 ] && echo "  未检测到串口设备（检查 USB 数据线是否插好、板子是否上电）"
  return 0
}

# ---- 参数解析 ---------------------------------------------------------------
# 位置参数简写：low/mcu→主控固件，cam→图传固件，/dev/ttyXXX→串口
while [ $# -gt 0 ]; do
  case "$1" in
    --port)       PORT="${2:-}"; shift 2 ;;
    --project)    PROJECT="${2:-}"; shift 2 ;;
    --baud)       BAUD="${2:-}"; shift 2 ;;
    --monitor)    DO_MONITOR=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --list)       list_ports; exit 0 ;;
    -h|--help)    usage ;;
    # 位置参数简写
    low|mcu)      PROJECT="mcu"; shift ;;
    cam|camera)   PROJECT="cam"; shift ;;
    /dev/tty*)    PORT="$1"; shift ;;
    *)            error "未知参数: $1"; usage ;;
  esac
done

# ---- 1. 加载 ESP-IDF --------------------------------------------------------
step "1/5 加载 ESP-IDF 环境"
if [ ! -f "$IDF_DIR/export.sh" ]; then
  error "未找到 $IDF_DIR/export.sh → 请先执行 03_install_espidf.sh"
  exit 1
fi

# 1.1 清除 ROS 2 / conda 对 Python 环境的污染
# 典型场景：~/.bashrc 里 source /opt/ros/humble/setup.bash
#   → PATH 上 python3 变成 /usr/bin/python3 (3.10)，
#   → export.sh 据此去找 ~/.espressif/python_env/idf5.5_py3.10_env，
#   → 但工具链实际装的是 py3.13_env → 找不到 → export.sh 末尾
#     `. <venv>/bin/activate` 失败 → 在 set -e 下直接终止本脚本。
# ESP-IDF 与 ROS 2 都会改 PYTHONPATH，二者不能共存于同一 shell。
unset PYTHONPATH PYTHONHOME
unset AMENT_PREFIX_PATH AMENT_CURRENT_PREFIX COLCON_PREFIX_PATH
unset ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION CMAKE_PREFIX_PATH

# 1.2 显式指定已安装的 ESP-IDF python 虚拟环境（别让 export.sh 靠 python3 猜版本）
#     依据：tools/idf_tools.py 的 get_python_env_path() 优先读 IDF_PYTHON_ENV_PATH
PYENV_DIR=""
for d in "$HOME"/.espressif/python_env/idf*_env; do
  [ -d "$d" ] && PYENV_DIR="$d"
done
if [ -n "$PYENV_DIR" ]; then
  export IDF_PYTHON_ENV_PATH="$PYENV_DIR"
else
  warn "未找到 ~/.espressif/python_env/*_env → 请先执行 03_install_espidf.sh"
fi

# 1.3 先在子 shell 里预跑一次，拿到 export.sh 的真实报错
#     不能直接 source + 重定向：export.sh 内部失败会终止调用方脚本，
#     配合 >/dev/null 2>&1 就是「静默退出」，完全看不到原因。
IDF_LOG="$(mktemp -t idf_export.XXXXXX)"
if ! ( source "$IDF_DIR/export.sh" ) >"$IDF_LOG" 2>&1; then
  error "加载 ESP-IDF 失败。export.sh 原始输出："
  sed 's/^/      /' "$IDF_LOG"
  rm -f "$IDF_LOG"
  echo ""
  echo "  常见原因与处理："
  echo "    ① .bashrc 里 source 了 ROS 2，导致 python3 版本串了"
  echo "       → 本脚本已自动清理 PYTHONPATH / ROS_* / AMENT_*，若仍失败请看下面 ②"
  echo "    ② ESP-IDF 的 python 虚拟环境缺失或版本不匹配"
  echo "       → 重新执行 03_install_espidf.sh"
  echo "    ③ 本终端手动 source 过 ROS 2 或 ESP-IDF，环境已串"
  echo "       → 开一个干净终端重试（不要手动 source 任何 setup）"
  exit 1
fi
rm -f "$IDF_LOG"

# 1.4 正式加载（已预跑验证，此处不应再失败）
# shellcheck disable=SC1090
source "$IDF_DIR/export.sh" >/dev/null 2>&1
command -v idf.py >/dev/null 2>&1 || { error "idf.py 不可用，ESP-IDF 环境异常"; exit 1; }
info "ESP-IDF $(idf.py --version 2>/dev/null | head -1)"

# ---- 2. 定位工程 ------------------------------------------------------------
step "2/5 定位固件工程"
case "$PROJECT" in
  mcu)
    PROJ_DIR="$PROJ_MCU_FALLBACK"
    DESC="下位机固件 leap_ros_mcu_driver（电机/里程计/IMU/雷达/micro-ROS）"
    ;;
  cam)
    PROJ_DIR="$PROJ_CAM_FALLBACK"
    DESC="WiFi 图传固件 esp32_s3_wifi_camera（MJPEG 视频流）"
    ;;
  *) error "未知工程: $PROJECT（可选 mcu / cam）"; exit 1 ;;
esac

if [ ! -d "$PROJ_DIR" ]; then
  error "工程目录不存在: $PROJ_DIR"
  echo ""
  echo "请先解压源码："
  echo "  # 下位机固件"
  echo "  mkdir -p ~/leap_firmware && tar -xf \"$SRC_ROOT/leap_ros.tar\" -C /tmp/"
  echo "  mv /tmp/leap_low_v1 ~/leap_firmware/"
  echo "  # WiFi 图传固件"
  echo "  unzip -q \"$SRC_ROOT/leap_cam.zip\" -d /tmp/ && mv /tmp/leap_cam ~/leap_firmware/"
  exit 1
fi
info "$DESC"
info "工程路径: $PROJ_DIR"
cd "$PROJ_DIR"

# ---- 2.1 修复 dependencies.lock 中的失效绝对路径 ---------------------------
# 原作者的 dependencies.lock 会缓存其本机绝对路径（如 /root/maturo_project/...）。
# 注意：IDF 组件管理器每次构建都会把 path 重写为「本机当前绝对路径」，这是正常的；
#       只有当该路径在本机不存在（指向别的机器）时才需要修正。
LOCK_FILE="$PROJ_DIR/dependencies.lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PATH=$(grep -E "^\s+path: " "$LOCK_FILE" 2>/dev/null | head -1 | sed -E 's/^\s+path: //')
  if [ -n "$LOCK_PATH" ] && [ ! -d "$LOCK_PATH" ]; then
    warn "dependencies.lock 组件路径失效: $LOCK_PATH"
    warn "正在修正为相对路径..."
    [ -f "$LOCK_FILE.orig" ] || cp "$LOCK_FILE" "$LOCK_FILE.orig"
    sed -i -E 's#^(\s+path: ).*/(managed_components/[^/]+)$#\1../\2#' "$LOCK_FILE"
    info "已修正，备份于 $LOCK_FILE.orig"
  fi
fi

# ---- 2.2 提前确定串口并检查权限（编译前，避免白等几分钟）--------------------
if [ $BUILD_ONLY -eq 0 ]; then
step "2/5 确定烧录串口并检查权限"

if [ -z "$PORT" ]; then
  # 自动探测唯一串口
  MAPFILE=()
  for d in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$d" ] && MAPFILE+=("$d"); done
  if [ "${#MAPFILE[@]}" -eq 1 ]; then
    PORT="${MAPFILE[0]}"
    info "自动检测到串口: $PORT"
  elif [ "${#MAPFILE[@]}" -eq 0 ]; then
    error "没有检测到任何串口设备"
    echo "  请检查：① USB 线已插好（要能传数据的线，不是纯充电线）② 板子已上电"
    echo "  查看设备： bash $0 --list"
    exit 1
  else
    error "检测到多个串口设备（${MAPFILE[*]}），需手动指定"
    echo "请用 --port 指定，例如: bash $0 $PROJECT --port /dev/ttyUSB0"
    exit 1
  fi
fi

[ -e "$PORT" ] || { error "串口不存在: $PORT"; exit 1; }

if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  error "当前用户无法读写 $PORT（烧录必然失败）"
  echo ""
  ls -l "$PORT" 2>/dev/null | sed 's/^/    /'
  VID=$(udevadm info -q property -n "$PORT" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
  PID=$(udevadm info -q property -n "$PORT" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
  [ -n "$VID" ] && echo "    芯片: $VID:$PID   本会话组: $(id -nG)"
  echo ""
  echo "  按顺序排查（三种原因）："
  echo "    ① udev 规则没匹配到该芯片 —— 例：CH340 实际是 1a86:7522，规则却只写了 7523"
  echo "       → sudo bash 11_fix_serial_perm.sh          # 一键修复"
  echo "    ② 你已在 dialout 组，但当前终端是加组之前开的"
  echo "       → newgrp dialout    （仅本终端生效）"
  echo "         或注销后重新登录   （永久生效）"
  echo "    ③ 设备刚插入，权限还没重新应用"
  echo "       → 拔掉 USB 线再插回"
  exit 1
fi
info "串口权限 OK（$PORT）"
fi

# ---- 3. 编译 ----------------------------------------------------------------
step "3/5 编译固件（target=$TARGET）"
# idf.py set-target 会触发 fullclean（清空 build/）→ 每次烧录都全量重编，很慢。
# 只有当 sdkconfig 里的目标不是我们要的，才真的需要 set-target。
if [ -f sdkconfig ] && grep -q "^CONFIG_IDF_TARGET=\"$TARGET\"" sdkconfig; then
  info "目标已是 $TARGET，跳过 set-target（保留增量编译）"
else
  info "设置目标为 $TARGET（会重建 sdkconfig）"
  idf.py set-target "$TARGET"
fi
idf.py build

if [ $BUILD_ONLY -eq 1 ]; then
  info "编译完成（--build-only，未烧录）"
  ls -lh build/*.bin 2>/dev/null || true
  exit 0
fi

# ---- 4. 烧录 ----------------------------------------------------------------
step "4/5 烧录固件"
info "烧录到 $PORT @ $BAUD"
idf.py -p "$PORT" -b "$BAUD" flash

# ---- 5. 监视 ----------------------------------------------------------------
if [ $DO_MONITOR -eq 1 ]; then
  step "5/5 打开串口监视（Ctrl+] 退出）"
  idf.py -p "$PORT" monitor
else
  step "5/5 完成"
  info "烧录成功！如需查看串口输出："
  echo "    idf.py -p $PORT monitor        # 或: bash $0 --port $PORT --monitor"
fi
