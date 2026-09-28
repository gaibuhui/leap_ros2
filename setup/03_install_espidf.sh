#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— ESP-IDF v5.5.3 安装脚本（无需 root）
# =============================================================================
# 作用：安装 ESP-IDF 工具链（esp32s3 目标），用于编译/烧录下位机固件
# 适用：Ubuntu 22.04 x86_64
# 用法：bash 03_install_espidf.sh
# 说明：ESP-IDF 安装到 ~/esp，工具链到 ~/.espressif，均为用户目录，无需 sudo
# =============================================================================
set -euo pipefail

IDF_VERSION="v5.5.3"
IDF_DIR="${IDF_DIR:-$HOME/esp/esp-idf}"
TARGET="${TARGET:-esp32s3}"
# 乐鑫国内镜像（速度远快于官方 dl.espressif.com）
export IDF_GITHUB_ASSETS="${IDF_GITHUB_ASSETS:-dl.espressif.cn/github_assets}"
# 系统 Python 为 3.10，ESP-IDF 官方要求 3.9~3.12，这里放宽检查
export IDF_PYTHON_CHECK_CONSTRAINT="${IDF_PYTHON_CHECK_CONSTRAINT:-no}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

# ---- 1. 依赖检查 ------------------------------------------------------------
step "1/4 检查依赖工具"
for c in git wget curl unzip tar; do
  command -v "$c" >/dev/null 2>&1 && info "$c 已安装" || { error "缺少 $c"; exit 1; }
done

# ESP-IDF 安装器需要 python venv；Ubuntu 需 python3-venv 包
if /usr/bin/python3 -c "import ensurepip" 2>/dev/null; then
  info "系统 Python venv 可用"
elif /usr/bin/python3 -m virtualenv --version >/dev/null 2>&1; then
  warn "系统缺 python3-venv，但检测到 virtualenv（$(/usr/bin/python3 -m virtualenv --version 2>&1 | head -1)），可继续"
else
  error "需要 python3-venv 或 virtualenv，请先执行："
  error "  sudo apt install -y python3-venv"
  error "  或 pip3 install --user virtualenv"
  exit 1
fi

# ---- 2. 获取 ESP-IDF 源码 ---------------------------------------------------
# 重要：Gitee 归档包 (repository/archive) 不含 git 子模块，会导致编译报
#       "Missing esp-mqtt submodule" 等错误，必须用 git clone --recurse-submodules。
step "2/4 获取 ESP-IDF $IDF_VERSION 源码（含子模块）"
if [ -f "$IDF_DIR/export.sh" ] && [ -n "$(ls -A "$IDF_DIR/components/mqtt/esp-mqtt" 2>/dev/null)" ]; then
  info "已存在且子模块完整: $IDF_DIR，跳过下载"
else
  mkdir -p "$(dirname "$IDF_DIR")"
  if [ -d "$IDF_DIR/.git" ] && [ -n "$(ls -A "$IDF_DIR/components" 2>/dev/null)" ]; then
    # 已有不完整仓库，补拉子模块
    info "检测到不完整安装，补拉 git 子模块..."
    git -C "$IDF_DIR" submodule update --init --recursive --depth 1
  else
    info "从 GitHub 克隆 $IDF_VERSION（含全部子模块，约 300MB，请耐心等待）..."
    info "如 GitHub 不可达，可用 gitee 镜像: https://gitee.com/EspressifSystems/esp-idf.git"
    GIT_URL="${IDF_GIT_URL:-https://github.com/espressif/esp-idf.git}"
    git clone --depth 1 --single-branch -b "$IDF_VERSION" \
      --recurse-submodules --shallow-submodules \
      "$GIT_URL" "$IDF_DIR"
  fi
  info "源码就位"
fi

# 子模块完整性自检
if [ -z "$(ls -A "$IDF_DIR/components/mqtt/esp-mqtt" 2>/dev/null)" ]; then
  error "子模块仍不完整（esp-mqtt 为空）"
  error "请手动执行: cd $IDF_DIR && git submodule update --init --recursive"
  exit 1
fi
info "子模块校验通过 ✓"

# ---- 3. 安装工具链 ----------------------------------------------------------
step "3/4 安装 $TARGET 工具链（xtensa 交叉编译器 + Python 环境）"
info "镜像: $IDF_GITHUB_ASSETS"
cd "$IDF_DIR"
./install.sh "$TARGET"

# ---- 4. 配置环境 ------------------------------------------------------------
step "4/4 配置 shell 环境"

# 4.1 先清掉本脚本早期版本写入的 get_idf 别名
#     旧版是 `alias get_idf='source .../export.sh >/dev/null'`，两个问题：
#       · ~/.bashrc 里 source 了 ROS 2 时会污染 PYTHONPATH，导致 python3 版本串掉，
#         export.sh 找不到对应的 python 虚拟环境而失败；
#       · alias 里无法可靠地 unset 多个变量。
#     新版改为函数，因此需要把旧块移除后重新写入。
if grep -q ">>> ESP-IDF .* (LEAP_ROS) >>>" "$HOME/.bashrc" 2>/dev/null; then
  cp "$HOME/.bashrc" "$HOME/.bashrc.leap-ros.bak"
  awk '/^# >>> ESP-IDF .* \(LEAP_ROS\) >>>$/ {skip=1; next}
       /^# <<< ESP-IDF .* \(LEAP_ROS\) <<<$/ {skip=0; next}
       !skip' "$HOME/.bashrc" > "$HOME/.bashrc.new" && mv "$HOME/.bashrc.new" "$HOME/.bashrc"
  info "已移除旧的 ESP-IDF 配置块（原文件备份为 ~/.bashrc.leap-ros.bak）"
fi

BASH_SNIPPET=$(cat << 'EOSNIP'

# >>> ESP-IDF @IDF_VERSION@ (LEAP_ROS) >>>
export IDF_GITHUB_ASSETS=dl.espressif.cn/github_assets

# 手动激活 ESP-IDF 环境（每个新终端执行）。
#
# 为什么必须是函数而不是 alias：
#   ~/.bashrc 里通常 source 了 ROS 2（如 /opt/ros/humble/setup.bash），
#   它会污染 PYTHONPATH，并使 PATH 上的 python3 指向别的版本；
#   export.sh 据此去找 ~/.espressif/python_env/idf*_py<该版本>_env，
#   但工具链实际装的是另一个版本 → 找不到 → export.sh 内部失败，
#   在 set -e 的脚本里就是「跑一半静默退出」。
#   所以这里先清理污染变量，再显式指定已安装的 python 虚拟环境。
#   alias 里没法可靠地 unset 变量，故用函数。
get_idf() {
    unset PYTHONPATH PYTHONHOME
    unset AMENT_PREFIX_PATH AMENT_CURRENT_PREFIX COLCON_PREFIX_PATH
    unset ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION CMAKE_PREFIX_PATH
    local _env_dir
    _env_dir=$(ls -d "$HOME"/.espressif/python_env/idf*_env 2>/dev/null | tail -1)
    [ -n "$_env_dir" ] && export IDF_PYTHON_ENV_PATH="$_env_dir"
    source "@IDF_DIR@/export.sh"
}
# <<< ESP-IDF @IDF_VERSION@ (LEAP_ROS) <<<
EOSNIP
)
BASH_SNIPPET="${BASH_SNIPPET//@IDF_DIR@/$IDF_DIR}"
BASH_SNIPPET="${BASH_SNIPPET//@IDF_VERSION@/$IDF_VERSION}"
printf '%s\n' "$BASH_SNIPPET" >> "$HOME/.bashrc"
info "已向 ~/.bashrc 写入 get_idf 函数（含 ROS 环境污染清理）"

echo ""
echo "=================================================================="
info "ESP-IDF $IDF_VERSION 安装完成！"
echo "=================================================================="
echo "激活环境（每个新终端手动执行）:"
echo "    get_idf          # 或: source $IDF_DIR/export.sh"
echo ""
echo "烧录固件请执行:"
echo "    bash 04_flash_firmware.sh --list      # 查看可用串口"
echo "    bash 04_flash_firmware.sh low         # 烧主控固件（自动探测串口）"
echo ""
echo "注意：ESP-IDF 与 ROS 2 的环境变量会相互干扰，"
echo "      建议在独立终端中分别使用（不要在同一终端同时 source 两者）。"
echo "      04_flash_firmware.sh 已内置环境隔离，直接用即可，无需先 get_idf。"
echo "=================================================================="
