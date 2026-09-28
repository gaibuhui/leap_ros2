#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 雷达虚拟串口 (socat) 权限配置【可选优化】
# =============================================================================
# 背景：
#   bringup_all.launch.py 中通过 socat 把 UDP:8889 转发为虚拟串口 /dev/lidar，
#   而创建 /dev/lidar 需要 root 权限。原 launch 文件把 sudo 密码硬编码为
#   "xuegeros"，既不安全，也会在密码不同的系统上失败。
#
# 本脚本提供两种解决方案（二选一）：
#   [A] 为 socat 配置免密 sudo（推荐）：launch 中的密码不再被使用，仍能工作
#   [B] 未配置免密时，打印手动启动命令
#
# 用法：bash 06_setup_lidar_socat.sh          # 方案 A（需 sudo）
#       bash 06_setup_lidar_socat.sh --manual # 只打印手动命令
# =============================================================================
set -euo pipefail

SUDO_PASSWORD="${SUDO_PASSWORD:-}"
USER_NAME="${USER:-$(id -un)}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

run_sudo() {
  if [ -n "$SUDO_PASSWORD" ]; then
    echo "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

show_manual() {
  echo "手动启动虚拟串口（保持该终端不关闭）："
  echo ""
  echo "  sudo socat -d -d PTY,link=/dev/lidar,raw,echo=0,mode=666 \\"
  echo "       UDP4-LISTEN:8889,reuseaddr,fork"
  echo ""
  echo "然后在另一个终端运行: bash 05_run_robot.sh agent   # 启动 micro-ROS Agent"
}

if [ "${1:-}" = "--manual" ]; then
  show_manual
  exit 0
fi

# ---- 方案 A：为 socat 配置 NOPASSWD -----------------------------------------
step "1/3 检查 socat 路径"
SOCAT_BIN="$(command -v socat || true)"
if [ -z "$SOCAT_BIN" ]; then
  error "未找到 socat，请先安装: sudo apt install -y socat"
  exit 1
fi
info "socat: $SOCAT_BIN"

step "2/3 写入 sudoers 免密规则"
SUDOERS_FILE="/etc/sudoers.d/leap_ros_socat"
TMP_FILE="$(mktemp)"
cat > "$TMP_FILE" <<EOF
# LEAP_ROS 雷达虚拟串口：允许 $USER_NAME 免密运行 socat
$USER_NAME ALL=(root) NOPASSWD: $SOCAT_BIN
EOF

# sudoers 必须用 visudo 校验权限与语法，否则会导致 sudo 全面失效
run_sudo install -m 0440 -o root -g root "$TMP_FILE" "$SUDOERS_FILE"
rm -f "$TMP_FILE"

if run_sudo visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
  info "sudoers 规则已生效: $SUDOERS_FILE"
else
  error "sudoers 语法校验失败，已回滚"
  run_sudo rm -f "$SUDOERS_FILE"
  exit 1
fi

step "3/3 验证"
if sudo -n "$SOCAT_BIN" -V >/dev/null 2>&1; then
  info "socat 免密 sudo 已可用 ✓"
else
  warn "免密验证未通过，请检查 $SUDOERS_FILE"
fi

echo ""
echo "=================================================================="
info "配置完成"
echo "=================================================================="
echo "现在 bringup_all.launch.py 中的硬编码密码 xuegeros 不再被使用，"
echo "启动整机时会直接用免密 sudo 运行 socat："
echo ""
echo "    bash 05_run_robot.sh bringup"
echo ""
echo "如需卸载该规则："
echo "    sudo rm -f $SUDOERS_FILE"
echo "=================================================================="
