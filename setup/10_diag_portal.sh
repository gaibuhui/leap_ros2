#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 配网页地址自动诊断
# =============================================================================
# 解决的核心问题：
#   机器人有【两块板子】，都会发 Maturo_ 开头的热点，但配网页地址完全不同：
#     · 主控板 leap_low_v1  → 热点 Maturo_<12位MAC>        → 配网页 http://192.168.4.1
#     · 图传板 leap_cam     → 热点 Maturo_CAM_<12位MAC>    → 配网页 http://192.168.1.88
#   连错热点访问 192.168.4.1，浏览器必然报"服务器响应时间过长"：
#   该地址不在本机任何网段内，数据包被丢给默认路由（通常是有线网口）出去了。
#
# 用法：
#   bash 10_diag_portal.sh
# =============================================================================
set -uo pipefail

MAIN_AP_IP="192.168.4.1"
CAM_AP_IP="192.168.1.88"

echo "=============================================================="
echo " LEAP_ROS 配网页诊断   $(date '+%F %T')"
echo "=============================================================="

hdr()  { echo -e "\n\033[1;36m┌─ $*\033[0m"; }
ok()   { echo -e "  \033[1;32m[OK]\033[0m   $*"; }
wn()   { echo -e "  \033[1;33m[警告]\033[0m $*"; }
bad()  { echo -e "  \033[1;31m[不通]\033[0m $*"; }

# ---- 1. 列出所有本机 IPv4 ---------------------------------------------------
hdr "1. 本机网络地址"

WIFI_IFACES=()
while IFS= read -r line; do
  IFACE=$(echo "$line" | awk '{print $2}')
  CIDR=$(echo  "$line" | awk '{print $4}')
  IP="${CIDR%%/*}"
  [ -d "/sys/class/net/$IFACE/wireless" ] || continue
  WIFI_IFACES+=("$IFACE")
  echo "     $IFACE  (WiFi)  $CIDR"
done < <(ip -o -4 addr show 2>/dev/null)

if [ ${#WIFI_IFACES[@]} -eq 0 ]; then
  bad "没有已连接的 WiFi 网卡"
  echo "     请先连接机器人的热点（Maturo_ 或 Maturo_CAM_ 开头），再跑本脚本。"
  exit 1
fi

# ---- 2. 逐个 WiFi 网卡：取网关并探测配网页 --------------------------------
hdr "2. 配网页探测"

FOUND_MAIN=0; FOUND_CAM=0; OTHER_GW=""

probe() {   # probe <url> -> 成功回显 <title>
  local url="$1" out
  # tr -d '\000' : 视频流端口可能返回二进制，去掉 null 字节避免 bash 告警
  out=$(curl -s --noproxy '*' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '\000') || return 1
  [ -z "$out" ] && return 1
  echo "$out" | grep -o -a -E '<title>[^<]*</title>' | head -1 | sed -E 's#</?title>##g'
  return 0
}

for IFACE in "${WIFI_IFACES[@]}"; do
  GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
  [ -z "$GW" ] && GW=$(ip route show dev "$IFACE" 2>/dev/null | awk '/via/{print $3; exit}')
  [ -z "$GW" ] && { wn "$IFACE 无网关（可能没拿到 DHCP）"; continue; }

  echo "     $IFACE → 网关/AP 地址: $GW"

  TITLE=$(probe "http://$GW/") && {
    ok "$IFACE 配网页可达: http://$GW/   标题: $TITLE"
    case "$GW" in
      "$CAM_AP_IP")  FOUND_CAM=1 ;;
      "$MAIN_AP_IP") FOUND_MAIN=1 ;;
      *)             OTHER_GW="$GW" ;;
    esac
  } || bad "$IFACE 网关 $GW 的 80 端口无响应"

  if [ "$FOUND_CAM" -eq 1 ]; then
    if probe "http://$GW:81/" >/dev/null; then
      ok "    图传流也可达: http://$GW:81/"
    fi
  fi
done

# ---- 3. 结论 ---------------------------------------------------------------
hdr "3. 结论"

if [ "$FOUND_CAM" -eq 1 ]; then
  echo -e "  当前连的是 \033[1;36m图传板 (leap_cam)\033[0m 的热点。"
  echo ""
  echo -e "  ▶ 配网页应打开：\033[1;37mhttp://$CAM_AP_IP/\033[0m"
  echo -e "  ▶ 视频流地址：  \033[1;37mhttp://$CAM_AP_IP:81/\033[0m"
  echo ""
  wn "此处【不是】192.168.4.1 —— 那是主控板的地址，在本网段不存在。"
  echo "     要配主控板（跑 ROS 必需），请断开当前 WiFi，"
  echo "     改连不带 CAM 的那个热点：Maturo_<12位MAC>，然后访问 http://192.168.4.1"
elif [ "$FOUND_MAIN" -eq 1 ]; then
  echo -e "  当前连的是 \033[1;36m主控板 (leap_low_v1)\033[0m 的热点。"
  echo ""
  echo -e "  ▶ 配网页应打开：\033[1;37mhttp://$MAIN_AP_IP/\033[0m"
  echo ""
  echo "     页面上要填：你的 WiFi 名/密码 + micro-ROS Agent IP(你电脑的IP) + 模式 micro_ros"
  echo "     查电脑 IP：bash 09_preflight.sh"
elif [ -n "$OTHER_GW" ]; then
  echo "  已连上某个网络（网关 $OTHER_GW），但没识别出机器人配网页。"
  echo "     识别到的 : $([[ -n "${TITLE:-}" ]] || echo '未知')"
  wn "看起来不是机器人的热点，请确认连的是 Maturo_ 开头（不带 -CAM 的是主控板，带 CAM_ 的是图传板）。"
else
  echo "  没有探测到任何可用的机器人配网页。"
  wn "请确认：1) 机器人已上电  2) 已连接 Maturo_ 开头的热点  3) 该热点无密码"
fi

# ---- 4. 路由自检（解释"为什么超时"）---------------------------------------
hdr "4. 路由自检 —— 验证 192.168.4.1 到底走了哪条路"

for target in "$MAIN_AP_IP" "$CAM_AP_IP"; do
  ROUTE=$(ip route get "$target" 2>/dev/null | head -1)
  if echo "$ROUTE" | grep -qE "dev (${WIFI_IFACES[*]// /|})\b"; then
    ok "$target 走 WiFi（本网段，正常）"
    echo "         $ROUTE"
  else
    bad "$target 不在本机任何网段 → 交给默认路由，从有线网口出去了，必然超时"
    echo "         $ROUTE"
  fi
done

echo ""
echo "=============================================================="
echo " 一块板子的热点名称 = 它的配网页地址，一一对应，别混："
echo "   Maturo_<12位MAC>      → 主控板 → http://192.168.4.1"
echo "   Maturo_CAM_<12位MAC>  → 图传板 → http://192.168.1.88"
echo "=============================================================="
echo ""
exit 0
