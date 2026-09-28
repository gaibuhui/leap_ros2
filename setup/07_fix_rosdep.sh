#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— rosdep 国内镜像修复脚本
# =============================================================================
# 作用：修复 `rosdep update` 报 429 / "Not all sources were able to be updated"
# 原因：rosdep 官方源与 rosdistro 索引都在 raw.githubusercontent.com 上，
#       该域名在国内经常限流（HTTP 429）或直接不可达，与网络策略无关，
#       换镜像即可彻底解决。
# 用法：bash 07_fix_rosdep.sh            # 使用默认清华 TUNA 镜像
#       MIRROR=https://xxx/rosdistro bash 07_fix_rosdep.sh
# 需要：sudo（仅用于改写 /etc/ros/rosdep/sources.list.d/20-default.list）
# =============================================================================
set -euo pipefail

MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/rosdistro}"
SOURCES_LIST=/etc/ros/rosdep/sources.list.d/20-default.list
ROS_DISTRO_NAME="humble"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }

# ---- 0. 校验镜像可用性 -------------------------------------------------------
step "0/4 校验镜像可用性"
if ! curl -fsSL -m 15 -o /dev/null "$MIRROR/index-v4.yaml" 2>/dev/null; then
  error "镜像不可用: $MIRROR/index-v4.yaml"
  error "可换用其它镜像后重试，例如："
  error "  MIRROR=https://mirrors.aliyun.com/rosdistro bash 07_fix_rosdep.sh"
  exit 1
fi
info "镜像可用: $MIRROR"

# ---- 1. 改写 rosdep sources list（需 sudo） -----------------------------------
step "1/4 将 rosdep 源切换为国内镜像"
sudo mkdir -p /etc/ros/rosdep/sources.list.d
if [ -f "$SOURCES_LIST" ] && [ ! -f "$SOURCES_LIST.orig" ]; then
  sudo cp "$SOURCES_LIST" "$SOURCES_LIST.orig"
  info "已备份原始文件 → $SOURCES_LIST.orig"
fi
sudo tee "$SOURCES_LIST" >/dev/null <<EOF
# os-specific listings first
yaml $MIRROR/rosdep/osx-homebrew.yaml osx

# generic
yaml $MIRROR/rosdep/base.yaml
yaml $MIRROR/rosdep/python.yaml
yaml $MIRROR/rosdep/ruby.yaml
gbpdistro $MIRROR/releases/fuerte.yaml fuerte
EOF
info "sources list 已写入 $SOURCES_LIST"

# ---- 2. 固化索引地址到 ~/.bashrc ---------------------------------------------
step "2/4 配置 ROSDISTRO_INDEX_URL 环境变量"
INDEX_URL="$MIRROR/index-v4.yaml"
export ROSDISTRO_INDEX_URL="$INDEX_URL"
if grep -qF "ROSDISTRO_INDEX_URL" "$HOME/.bashrc" 2>/dev/null; then
  info "~/.bashrc 已包含 ROSDISTRO_INDEX_URL，跳过"
else
  {
    echo ""
    echo "# >>> rosdep 国内镜像 (LEAP_ROS) >>>"
    echo "export ROSDISTRO_INDEX_URL=$INDEX_URL"
    echo "# <<< rosdep 国内镜像 (LEAP_ROS) <<<"
  } >> "$HOME/.bashrc"
  info "已写入 ~/.bashrc: export ROSDISTRO_INDEX_URL=$INDEX_URL"
fi

# ---- 3. 清理旧缓存并更新 -----------------------------------------------------
step "3/4 刷新 rosdep 缓存（rosdep update）"
# 上次失败可能留下不完整的缓存，清掉以避免复用到坏数据
if [ -d "$HOME/.ros/rosdep/sources.cache" ]; then
  rm -rf "$HOME/.ros/rosdep/sources.cache"
  info "已清理旧缓存 ~/.ros/rosdep/sources.cache"
fi
if rosdep update --rosdistro "$ROS_DISTRO_NAME"; then
  info "rosdep update 成功"
else
  error "rosdep update 仍然失败，请检查网络后重试"
  exit 1
fi

# ---- 4. 验证 -----------------------------------------------------------------
step "4/4 验证 rosdep 可解析依赖"
if rosdep resolve --rosdistro "$ROS_DISTRO_NAME" python3-yaml >/dev/null 2>&1; then
  info "rosdep resolve 正常"
else
  warn "rosdep resolve 未通过（可能缓存尚未完全建立，可重跑本脚本）"
fi
# 统计已建立的 distro 缓存条目
CACHE_N=$(find "$HOME/.ros/rosdep/sources.cache" -name '*.yaml' 2>/dev/null | wc -l)
info "本机 rosdep 缓存文件数: $CACHE_N"

echo ""
echo "=================================================================="
info "rosdep 修复完成"
echo "=================================================================="
echo "之后可以直接使用："
echo "  rosdep install --from-paths ~/leap_ros_ws/src --ignore-src -r -y"
echo ""
echo "如需还原官方源："
echo "  sudo cp $SOURCES_LIST.orig $SOURCES_LIST"
echo "  unset ROSDISTRO_INDEX_URL   # 并删除 ~/.bashrc 中的对应行"
echo "=================================================================="
