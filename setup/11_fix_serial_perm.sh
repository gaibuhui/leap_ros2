#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 串口权限修复（USB 转串口设备打不开时用这个）
# =============================================================================
# 症状：
#   · idf.py flash 报 "could not open port /dev/ttyUSB0" / "Permission denied"
#   · ls -l /dev/ttyUSB0 显示 root:dialout 660，而当前用户打不开
#   · 明明已在 dialout 组里（01 脚本加过），但当前终端就是读不了
#
# 三个独立原因，本脚本一次性解决：
#   1) udev 规则写死了 CH340 的 idProduct=="7523"，但实际芯片可能是 1a86:7522
#      → 规则不匹配 → 权限停在默认的 660（而非规则里的 0666）
#   2) dialout 组成员身份需要**重新登录**才进当前会话（newgrp 只能治当前终端）
#   3) 已插入的设备不会因 reload-rules 自动重新应用权限，必须重新触发/拔插
#
# 用法：
#   sudo bash 11_fix_serial_perm.sh
#   sudo bash 11_fix_serial_perm.sh --port /dev/ttyUSB0   # 指定设备重点修复
# =============================================================================
set -uo pipefail

RULE_FILE="/etc/udev/rules.d/99-robot-serial.rules"
TARGET_PORT="${1:-}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

echo "=============================================================="
echo " LEAP_ROS 串口权限修复"
echo "=============================================================="

if [ "$EUID" -ne 0 ]; then
  error "需要 root 权限"
  echo "  请这样运行： sudo bash $0"
  exit 1
fi

# 解析 --port
if [ "${TARGET_PORT:-}" = "--port" ]; then TARGET_PORT="${2:-}"; fi
if [ -n "$TARGET_PORT" ] && [ ! -e "$TARGET_PORT" ]; then
  warn "指定设备不存在: $TARGET_PORT（继续按自动探测处理）"
  TARGET_PORT=""
fi

# ---- 1. 现状 ---------------------------------------------------------------
step "1/5 当前串口设备现状"

FOUND_ANY=0
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$dev" ] || continue
  FOUND_ANY=1
  PERM=$(stat -c '%U:%G %a' "$dev")
  VID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
  PID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
  DRV=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_USB_DRIVER=//p')
  echo "     $dev   $PERM   芯片=${VID:-?}:${PID:-?}  驱动=${DRV:-?}"
done
[ "$FOUND_ANY" -eq 0 ] && warn "没有检测到任何 /dev/ttyUSB* 或 /dev/ttyACM* 设备（板子插好了吗？）"

# ---- 2. 写入修正后的 udev 规则 --------------------------------------------
step "2/5 写入修正后的 udev 规则"

[ -f "$RULE_FILE" ] && cp -n "$RULE_FILE" "$RULE_FILE.bak" && info "原规则已备份到 $RULE_FILE.bak"

cat > "$RULE_FILE" <<'EOF'
# LEAP_ROS 机器人串口设备权限
# 修改说明：QinHeng(1a86) 有多个 product id —— CH340 常见 7523，
#          但部分批次/内核上报 7522；写死 7523 会漏匹配，导致权限停在 660。
#          故 1a86 按 vendor 通配。TAG+="uaccess" 让当前登录用户免重登即可访问。
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0666", GROUP="dialout", TAG+="uaccess"
# CP210x (Silicon Labs)
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666", GROUP="dialout", TAG+="uaccess"
# ESP32-S3 原生 USB-CDC / JTAG
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0666", GROUP="dialout", TAG+="uaccess"
# FTDI
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666", GROUP="dialout", TAG+="uaccess"
EOF
info "已写入 $RULE_FILE"

# ---- 3. 重载并重新触发 -----------------------------------------------------
step "3/5 重载 udev 规则并重新应用权限"

udevadm control --reload-rules     && info "已 reload-rules"
udevadm trigger --subsystem-match=tty --action=change && info "已 trigger tty 子系统"

# 对已插入的具体设备再单独触发一次（reload 不会自动重设已有节点权限）
if [ -n "$TARGET_PORT" ]; then
  udevadm trigger --action=change --name-match="$TARGET_PORT" 2>/dev/null && info "已单独触发 $TARGET_PORT"
else
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    udevadm trigger --action=change --name-match="$dev" 2>/dev/null && info "已单独触发 $dev"
  done
fi
sleep 1

# ---- 4. 验证 ---------------------------------------------------------------
step "4/5 验证权限"

OK_ALL=1
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$dev" ] || continue
  PERM=$(stat -c '%U:%G %a' "$dev")
  MODE=$(stat -c '%a' "$dev")
  if [ "$MODE" = "666" ] || [ "$MODE" = "664" ]; then
    info "$dev  → $PERM   ✅ 已修复"
  else
    warn "$dev  → $PERM   ⚠️ 仍是 $MODE"
    OK_ALL=0
  fi
done

if [ "$OK_ALL" -eq 0 ]; then
  echo ""
  warn "规则已写入，但已插入的设备可能仍需重新枚举才生效。"
  echo "     请执行其一："
  echo "       ① 拔掉 USB 线再插回（最有效）"
  echo "       ② 或跑： sudo udevadm trigger --action=add --subsystem-match=tty"
  echo ""
  echo "     若仍不行，用 dialout 组兜底（需重新登录）："
  echo "       当前终端临时生效： newgrp dialout"
  echo "       永久生效：         注销后重新登录"
fi

# ---- 5. dialout 组兜底 -----------------------------------------------------
step "5/5 dialout 组兜底检查"

if getent group dialout | grep -q "\b${SUDO_USER:-$USER}\b"; then
  info "用户 ${SUDO_USER:-$USER} 已在 dialout 组（需重新登录才进当前会话）"
else
  warn "用户 ${SUDO_USER:-$USER} 不在 dialout 组，正在加入..."
  usermod -aG dialout "${SUDO_USER:-$USER}" && info "已加入，注销重登后生效（或用 newgrp dialout）"
fi

echo ""
echo "=============================================================="
echo " 修复完成。现在可以烧录："
echo "   bash 04_flash_firmware.sh --port /dev/ttyUSB0"
echo "=============================================================="
echo ""
