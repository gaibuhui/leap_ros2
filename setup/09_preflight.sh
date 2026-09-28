#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 运行前预检（连接机器人之前先跑这个）
# =============================================================================
# 作用：
#   1. 检查上位机环境（ROS 2 / 工作空间 / micro-ROS Agent 可执行文件）
#   2. 打印本机 IP —— 这一项要填到机器人配网页的 "micro-ROS Agent IP" 里
#   3. 检查关键端口是否被占用（8888 micro-ROS / 8889 雷达桥）
#   4. 检查相机视频流地址是否可达
#   5. 检查机器人是否已连上（能否 ping 通）
#
# 用法：
#   bash 09_preflight.sh                  # 全量预检
#   bash 09_preflight.sh 192.168.1.50     # 额外检查指定机器人 IP 的连通性
# =============================================================================
set -uo pipefail

ROS_DISTRO_NAME="humble"
WS_DIR="${WS_DIR:-$HOME/leap_ros_ws}"
CAMERA_CFG="$WS_DIR/src/xuegecar_camera/config/http_video_publisher.yaml"
ROBOT_IP="${1:-}"

PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo -e "  \033[1;32m[PASS]\033[0m $*"; }
wn()   { WARN=$((WARN+1)); echo -e "  \033[1;33m[WARN]\033[0m $*"; }
no()   { FAIL=$((FAIL+1)); echo -e "  \033[1;31m[FAIL]\033[0m $*"; }
title(){ echo -e "\n\033[1;36m┌─ $*\033[0m"; }

echo "=============================================================="
echo " LEAP_ROS 运行前预检   $(date '+%F %T')"
echo "=============================================================="

# ---- 1. 上位机环境 ----------------------------------------------------------
title "1. 上位机环境"

if [ -f "/opt/ros/$ROS_DISTRO_NAME/setup.bash" ]; then
  ok "ROS 2 $ROS_DISTRO_NAME 已安装"
else
  no "ROS 2 $ROS_DISTRO_NAME 未安装 → 执行 01_install_ros2_humble.sh"
fi

if [ -f "$WS_DIR/install/setup.bash" ]; then
  ok "工作空间已编译：$WS_DIR/install"
else
  no "工作空间未编译 → 执行 02_build_workspace.sh"
fi

AGENT_BIN="$WS_DIR/install/micro_ros_agent/lib/micro_ros_agent/micro_ros_agent"
if [ -x "$AGENT_BIN" ]; then
  ok "micro-ROS Agent 可执行文件就绪"
else
  no "未找到 micro-ROS Agent → 重新执行 02_build_workspace.sh"
fi

for cmd in socat ping ss; do
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd 已安装" || wn "$cmd 未安装"
done

# ---- 2. 串口设备（烧录用）---------------------------------------------------
title "2. 串口设备（烧录固件用）"

SERIAL_FOUND=""
for dev in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$dev" ] || continue
  SERIAL_FOUND="$dev"
  PERM=$(stat -c '%U:%G %a' "$dev")
  VID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
  PID=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
  if [ -r "$dev" ] && [ -w "$dev" ]; then
    ok "$dev 可读写（$PERM，芯片 ${VID:-?}:${PID:-?}）"
  else
    no "$dev 不可读写（$PERM，芯片 ${VID:-?}:${PID:-?}）"
    echo "       本会话组: $(id -nG)"
    echo "       修复: sudo bash 11_fix_serial_perm.sh"
    echo "             或 newgrp dialout / 注销重登"
    if [ -n "$VID" ] && ! grep -qs "idVendor.*\"$VID\"" /etc/udev/rules.d/99-robot-serial.rules 2>/dev/null; then
      echo "       疑似 udev 规则未覆盖 ${VID}:${PID}（常见：CH340 的 1a86:7522 被漏掉）"
    fi
  fi
done

if [ -z "$SERIAL_FOUND" ]; then
  wn "未检测到 /dev/ttyUSB* 或 /dev/ttyACM* —— 固件已烧好可忽略；需烧录请插好 USB"
fi

# ---- 3. 本机 IP（配网要用）--------------------------------------------------
title "3. 本机网络地址  ← 配网页要填这个"

MAIN_AP_IP="192.168.4.1"    # 主控板 AP 地址（热点 Maturo_<MAC>）
CAM_AP_IP="192.168.1.88"    # 图传板 AP 地址（热点 Maturo_CAM_<MAC>）
WIFI_IP=""
WIFI_IP_IFACE=""
WIFI_IP_IS_WIFI=0
ON_ROBOT_AP=0

while IFS= read -r line; do
  IFACE=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
  CIDR=$(echo "$line" | awk '{print $4}')
  IP="${CIDR%%/*}"
  STATE=$(echo "$line" | awk '{print $1}')
  [ "$STATE" = "DOWN" ] && continue
  case "$IFACE" in
    lo|docker*|br-*|veth*|virbr*|tun*|tap*) continue ;;
  esac
  TYPE="有线/其他"
  if [ -d "/sys/class/net/$IFACE/wireless" ]; then TYPE="WiFi"; fi
  echo "     $IFACE  [$TYPE]  $IP"

  # 该网卡网关若是机器人自己的 AP，说明此刻连的是配网热点，IP 只是临时的
  GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
  if [ "$GW" = "$MAIN_AP_IP" ] || [ "$GW" = "$CAM_AP_IP" ]; then
    ON_ROBOT_AP=1
    wn "     ↑ 该网卡正连着机器人配网热点（$GW），这里拿到的 IP 只是临时的"
  fi

  # 优先记录 WiFi 地址 —— 机器人和上位机通常在同一 WiFi 下
  if [ -z "$WIFI_IP" ] || { [ "$TYPE" = "WiFi" ] && [ "$WIFI_IP_IS_WIFI" -eq 0 ]; }; then
    WIFI_IP="$IP"; WIFI_IP_IFACE="$IFACE"
    if [ "$TYPE" = "WiFi" ]; then WIFI_IP_IS_WIFI=1; else WIFI_IP_IS_WIFI=0; fi
  fi
done < <(ip -o -4 addr show 2>/dev/null)

if [ -n "$WIFI_IP" ]; then
  echo ""
  echo -e "  \033[1;33m>>> 把下面这个 IP 填到机器人配网页的 \"micro-ROS Agent IP\" 里：\033[0m"
  echo -e "  \033[1;37m      $WIFI_IP\033[0m    (网卡 $WIFI_IP_IFACE)"
  if [ "$ON_ROBOT_AP" -eq 1 ]; then
    echo ""
    wn "这个 IP 是【临时地址】，现在还不能填！因为你的电脑连着机器人自己的配网热点。"
    echo "     正确顺序："
    echo "       ① 连机器人配网热点 → 填 WiFi 名/密码 → 保存，机器人重启"
    echo "       ② 电脑也连到同一个路由器（别连机器人热点了）"
    echo "       ③ 再跑一次本脚本，拿到的才是正式 IP → 回配网页改 Agent IP"
    echo "     判别当前连的是哪块板：bash 10_diag_portal.sh"
  else
    echo "     （配网页地址：主控板 http://192.168.4.1 ｜ 图传板 http://192.168.1.88）"

    # 有线网卡接路由器同样可行：机器人走 WiFi、上位机走有线，只要在同一个 LAN 就能互通
    if [ "$WIFI_IP_IS_WIFI" -eq 0 ]; then
      echo ""
      echo "     说明：本机现在走【有线网卡】，没有已连接的 WiFi。这本身不是问题 ——"
      echo "     只要这根网线接的是【和机器人同一个路由器 / 同一个 LAN】，就能互通（已实测可行）。"
      echo "     要警惕的是接校园网/公司网（有认证、AP 隔离）：那样机器人进不来，填了也没用。"
    fi
    case "$WIFI_IP" in
      10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        wn "这个地址属于 10.x / 172.16-31.x 大内网网段，常见于校园网/公司网。"
        echo "     若机器人无法加入该网段，请改用家用路由器（如 192.168.31.x）"
        ;;
    esac
  fi
else
  no "未检测到可用网卡 IP，请检查网络连接"
fi

# ---- 4. 端口占用 ------------------------------------------------------------
title "4. 关键端口占用"

for p in 8888 8889; do
  if ss -lun 2>/dev/null | grep -q ":$p "; then
    wn "UDP :$p 已被占用（若已有 Agent/socat 在跑属正常）"
  else
    ok "UDP :$p 空闲"
  fi
done

if ss -lun 2>/dev/null | grep -q ":8888 "; then
  echo "     提示：8888 已有监听 —— 说明 micro-ROS Agent 可能已在运行"
fi

# ---- 5. 相机视频流 ----------------------------------------------------------
title "5. 相机视频流地址"

if [ -f "$CAMERA_CFG" ]; then
  CAM_URL=$(grep -E '^\s*url:' "$CAMERA_CFG" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
  echo "     当前配置: $CAM_URL"
  CAM_HOST=$(echo "$CAM_URL" | sed -E 's#https?://([^:/]+).*#\1#')
  if [ -n "$CAM_HOST" ]; then
    if ping -c 1 -W 1 "$CAM_HOST" >/dev/null 2>&1; then
      ok "相机 $CAM_HOST 可 ping 通"
    else
      wn "相机 $CAM_HOST ping 不通（配网前属正常）"
      echo "     若机器人已在运行仍不通 → 修改 $CAMERA_CFG 中的 url"
    fi
    if echo "$CAM_URL" | grep -qE "192\.168\.31\.(185|214)"; then
      wn "检测到该地址疑似作者默认值，需改成你自己机器人上摄像头的实际 IP"
    fi
  fi
else
  wn "未找到相机配置文件 $CAMERA_CFG"
fi

# ---- 6. 机器人发现与状态 ----------------------------------------------------
title "6. 机器人发现与状态"

# 自动发现：扫本网段，找 /api/status 里 device_name 以 Maturo_ 开头的设备。
# 关键事实：主控板在 STA 模式下也会开配网页（TCP 80），
# 所以只要机器人连上同一 WiFi，就能用 HTTP 直接读它的状态、甚至改配置，
# 完全不需要去连它的 AP 热点。
discover_robot() {
  local iface="$1" base="$2" neigh hits
  hits=$(mktemp)
  # 主动 ping 一遍，把同网段在线设备填进 ARP 表（并行，约 5~10 秒）
  seq 1 254 | xargs -P 64 -I{} sh -c "ping -c1 -W1 ${base}.{} >/dev/null 2>&1" 2>/dev/null
  # 只挑 ARP 里"真正在线"的条目 —— 必须排掉 FAILED/INCOMPLETE，
  # 否则会对着一堆不可达地址逐个 curl，慢到分钟级
  neigh=$(ip neigh show dev "$iface" 2>/dev/null \
          | awk '$1 ~ /^[0-9]/ && $NF != "FAILED" && $NF != "INCOMPLETE" {print $1}')
  [ -z "$neigh" ] && { rm -f "$hits"; return 1; }
  # 并发探测 /api/status，匹配到 device_name 以 Maturo_ 开头即为机器人
  printf '%s\n' "$neigh" | xargs -P 32 -I{} sh -c \
    'curl -s --noproxy "*" --connect-timeout 1 --max-time 2 "http://{}/api/status" 2>/dev/null | grep -q "\"device_name\":\"Maturo_" && echo "{}"' \
    > "$hits" 2>/dev/null
  if [ -s "$hits" ]; then head -1 "$hits"; rm -f "$hits"; return 0; fi
  rm -f "$hits"; return 1
}

if [ -z "$ROBOT_IP" ] && [ -n "${WIFI_IP_IFACE:-}" ] && [ -n "${WIFI_IP:-}" ]; then
  echo "     正在扫描本网段寻找机器人（约 15 秒）……"
  ROBOT_IP=$(discover_robot "$WIFI_IP_IFACE" "${WIFI_IP%.*}") || ROBOT_IP=""
fi

if [ -z "$ROBOT_IP" ]; then
  wn "未发现机器人（可手动指定: bash 09_preflight.sh <机器人IP>）"
  echo "       排查：① 机器人是否已上电  ② 主控板【白灯是否常亮】——常亮=已连上 WiFi"
  echo "             ③ 是否和电脑连同一个 WiFi/热点（ESP32 只支持 2.4GHz）"
else
  ok "发现机器人：$ROBOT_IP"
  R_STATUS=$(curl -s --noproxy '*' --connect-timeout 2 --max-time 6 "http://$ROBOT_IP/api/status" 2>/dev/null)
  if [ -z "$R_STATUS" ]; then
    no "$ROBOT_IP 无 HTTP 响应"
    ping -c 2 -W 1 "$ROBOT_IP" >/dev/null 2>&1 \
      && echo "       ping 通但 HTTP 不通 → 板子可能还在启动，等 10 秒再试" \
      || echo "       ping 也不通 → 不在同一网段，或被 AP 隔离"
  else
    gs() { echo "$R_STATUS" | grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
    gn() { echo "$R_STATUS" | grep -o "\"$1\":[0-9.-]*" | head -1 | cut -d: -f2; }
    gb() { echo "$R_STATUS" | grep -o "\"$1\":[a-z]*" | head -1 | cut -d: -f2; }
    R_SSID=$(gs ssid); R_RSSI=$(gn rssi); R_MODE=$(gs comm_mode)
    R_AIP=$(gs microros_agent_ip); R_PORT=$(gn microros_agent_port)
    R_LIDAR=$(gn valid_points); R_BAT=$(gn percentage); R_TEMP=$(gn celsius)
    R_STA=$(gb sta_connected)
    echo "       WiFi     : ${R_SSID:-?}  已连接=${R_STA:-?}  信号 ${R_RSSI:-?} dBm"
    echo "       通信模式 : ${R_MODE:-?}   Agent: ${R_AIP:-?}:${R_PORT:-?}"
    echo "       雷达点数 : ${R_LIDAR:-?}   电量 ${R_BAT:-?}%   温度 ${R_TEMP:-?}℃"

    [ "$R_MODE" = "micro_ros" ] \
      && ok "通信模式 = micro_ros" \
      || no "通信模式是 ${R_MODE:-空}，必须是 micro_ros（在配网页里改）"

    if [ -n "${WIFI_IP:-}" ] && [ "$R_AIP" = "$WIFI_IP" ]; then
      ok "Agent IP 与本机一致（$WIFI_IP）—— 配置正确"
    elif [ -n "${WIFI_IP:-}" ]; then
      no "Agent IP 是 ${R_AIP:-空}，本机是 $WIFI_IP → 不一致，机器人连不上"
      echo "       修法（无需连机器人热点，直接走 HTTP）:"
      echo "       curl -X POST http://$ROBOT_IP/api/runtime-config \\"
      echo "         -H 'Content-Type: application/x-www-form-urlencoded' \\"
      echo "         --data 'comm_mode=micro_ros&microros_agent_ip=$WIFI_IP&microros_agent_port=8888'"
      echo "       （返回 {\"ok\":true,\"restart\":true}，机器人自动重启约 10 秒）"
    fi

    # 相机地址一致性：机器人自己知道它那块图传板的实际地址（camera.stream_url）
    R_CAM=$(gs stream_url)
    if [ -n "$R_CAM" ]; then
      echo "       相机地址 : ${R_CAM}（机器人上报的实际值）"
      if [ -z "${CAM_URL:-}" ]; then
        :
      elif [ "$CAM_URL" = "$R_CAM" ]; then
        ok "相机配置与机器人一致（$R_CAM）"
      else
        wn "相机配置是 $CAM_URL，机器人实际是 $R_CAM → 不一致，视频流会连不上"
        echo "       影响范围：只有 bash 05_run_robot.sh cam（视频流），不影响雷达/建图/导航。"
        echo "       修法 A（推荐，改文件）: 把 $CAMERA_CFG 里的 url 改成 $R_CAM 后 colcon build"
        echo "       修法 B（不改文件）    : bash 05_run_robot.sh cam   # 已支持自动问机器人要地址"
      fi
    fi
  fi
fi

# ---- 汇总 -------------------------------------------------------------------
echo ""
echo "=============================================================="
echo -e " 汇总：\033[1;32mPASS $PASS\033[0m / \033[1;33mWARN $WARN\033[0m / \033[1;31mFAIL $FAIL\033[0m"
echo "=============================================================="

if [ "$FAIL" -eq 0 ]; then
  if ss -lun 2>/dev/null | grep -q ":8888 "; then
    echo -e "\033[1;33m注意：UDP :8888 已有 micro-ROS Agent 在运行\033[0m"
    echo "  若机器人还没连上（日志里没有 session established），复位一次即可："
    echo "    【终端 B】bash 05_run_robot.sh reset     # 等价按主控板 RESET 键"
    echo "    【终端 B】bash 05_run_robot.sh topics    # 验证会话 + 话题"
  else
    echo -e "环境就绪。\033[1;33m启动顺序很关键 —— 必须【先起 Agent，再让机器人连】\033[0m"
    echo "  【终端 A】bash 05_run_robot.sh core      # 一直开着（含 Agent + 机器人模型/TF）"
    echo "  【终端 B】bash 05_run_robot.sh reset     # ★ 复位机器人（等价按 RESET 键）"
    echo "  【终端 B】bash 05_run_robot.sh topics    # 验证会话 + /scan /odom /imu"
    echo ""
    echo "  （也可物理按一下主控板【复位键】代替 reset；core 自己会在 12 秒内报会话状态）"
    echo "  为什么顺序不能反：固件里一旦连接建立，rcl_wait 超时被当作'正常'，"
    echo "  机器人不会重新去 ping Agent。所以 Agent 后起时它【不会自愈重连】，只能靠重启。"
  fi
  echo ""
  echo "终端分工（A 链路／B 检查／C 遥控／D 建图导航／E 烧录）见：setup/新手全流程指南.md"
else
  echo "请先解决上面的 FAIL 项，再连接机器人。"
fi
echo ""

exit 0
