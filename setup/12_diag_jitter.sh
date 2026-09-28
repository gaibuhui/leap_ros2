#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 「地图 / 扫描抖动」专项诊断（上位机）
# =============================================================================
# 用法：
#   bash 12_diag_jitter.sh                 # 自动发现机器人
#   bash 12_diag_jitter.sh 10.182.70.244   # 指定机器人 IP
#   SAMPLE_SEC=30 bash 12_diag_jitter.sh   # 采样时长（默认 16 秒）
#
# 前提（很重要）：
#   * 机器人【必须静止不动】。车在动的时候测，结果没有意义。
#   * 【终端 A】core 链路在跑，【终端 D】slam 在跑，RViz 能看见地图。
#
# 它量四件事并给出判定：
#   1) /odom 自身：静止时 odom→base_footprint 的偏航抖动（里程计噪声）
#   2) map→odom：静止时是否稳定（gmapping 修正是否滞后/跳变）
#   3) 机器人内部：motion.yaw 与 imu.yaw 各自是否在漂（绕开 ROS 直接问固件）
#   4) /scan 质量：零值比例、最长连续零段、实际频率
#
# 输出末尾会给一段「结论」，直接说明抖动来自哪一层。
# =============================================================================
set -uo pipefail

ROS_DISTRO_NAME="humble"
WS_DIR="${WS_DIR:-$HOME/leap_ros_ws}"
ROBOT_IP="${1:-${ROBOT_IP:-}}"
SAMPLE_SEC="${SAMPLE_SEC:-16}"
TF_HZ="${TF_HZ:-30}"          # TF 采样率；tf2_echo 默认 1 Hz 太少（见 sample_tf 注释）
DEG=57.2957795

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

# ---- 统计：从 stdin 读数列，输出 "n min max 峰峰值 标准差" --------------------
stats() {
  awk '
    { v[n++]=$1+0; if(n==1){mn=$1+0; mx=$1+0} if($1+0<mn)mn=$1+0; if($1+0>mx)mx=$1+0; s+=$1+0 }
    END{
      if(n==0){ print "0 0 0 0 0"; exit }
      m=s/n; ss=0; for(i=0;i<n;i++){d=v[i]-m; ss+=d*d}
      printf "%d %.6f %.6f %.6f %.6f\n", n, mn, mx, mx-mn, sqrt(ss/n)
    }'
}

# 采 TF 某一列：$1=parent $2=child $3=RPY|RPY_DEG|Translation $4=列号 $5=秒
# 两个坑（都实测踩过，写在这里免得再犯）：
#  1) RPY 必须只取 "(radian)" 那一行 —— 直接 grep RPY 会同时命中 (radian) 和
#     (degree) 两行，弧度角度混在一条数列里，峰峰值会算出 17000° 这种离谱值。
#  2) tf2_echo 默认只有 **1 Hz**，必须加 -r，否则 16 秒只采 16 个样本，判不出抖动。
sample_tf() {
  local pat
  case "$3" in
    RPY|rpy)         pat='RPY (radian)' ;;
    RPY_DEG|rpy_deg) pat='RPY (degree)' ;;
    *)               pat="$3" ;;
  esac
  timeout "$5" ros2 run tf2_ros tf2_echo "$1" "$2" -r "${TF_HZ:-30}" 2>/dev/null \
    | grep -F "$pat" \
    | sed 's/.*\[\(.*\)\]/\1/' \
    | awk -F',' -v c="$4" '{gsub(/ /,"",$c); if($c ~ /^[-0-9]/) print $c}'
}

# 判断一列数值是否「只在两组离散值之间交替」—— 两个广播者抢同一条 TF 边的签名。
# 输出: <不同值个数> <主值1> <占比1%> <主值2> <占比2%> <两者合计占比%> <两值之差>
two_cluster() {
  awk '
    { c[$1+0]++; n=NR }
    END{
      if (n==0){ print "0 0 0 0 0 0 0"; exit }
      c1=0; c2=0
      for (k in c) {
        if (c[k] > c1)      { c2=c1; k2=k1; c1=c[k]; k1=k }
        else if (c[k] > c2) { c2=c[k]; k2=k }
      }
      d = k1 - k2; if (d < 0) d = -d
      printf "%d %.4f %.1f %.4f %.1f %.1f %.4f\n", \
             length(c), k1, 100.0*c1/n, k2, 100.0*c2/n, 100.0*(c1+c2)/n, d
    }'
}

# ---- 0. 环境 ---------------------------------------------------------------
info "加载 ROS 2 与环境…"
# shellcheck disable=SC1091
set +u
source "/opt/ros/${ROS_DISTRO_NAME}/setup.bash" 2>/dev/null
if [ -f "$WS_DIR/install/setup.bash" ]; then
  source "$WS_DIR/install/setup.bash" 2>/dev/null
else
  error "没找到 $WS_DIR/install/setup.bash —— 先构建工作空间"
  exit 1
fi
set -u
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"

echo ""
bold "──────────────── 0. 链路自检 ──────────────────────────────"
if pgrep -f 'micro_ros_agent udp4' >/dev/null 2>&1; then
  ok "micro-ROS Agent 在运行"
else
  error "没有 micro-ROS Agent 在跑 —— 先在【终端 A】执行： bash 05_run_robot.sh core"
  exit 1
fi
if ! ros2 topic list 2>/dev/null | grep -qx '/scan'; then
  error "/scan 不存在 —— 机器人没连上，或【终端 D】的 slam/链路没起来"
  exit 1
fi
if ! ros2 topic list 2>/dev/null | grep -qx '/odom'; then
  warn "/odom 不在话题列表里（如果你用的是官方 bringup，/odom 由固件发布，应当存在）"
fi
ok "/scan 存在"

# ---- 0b. 定位栈冲突（抖动的头号嫌疑，先查它）-------------------------------
# 判据用 **ROS 图**而不是进程名：amcl 跑在 component_container 里，
# 按进程名根本认不出来（踩过）。而 /map 的发布者是谁，ROS 图会直接告诉你：
#   gmapping 在跑 → 发布者只有 slam_gmapping
#   Nav2 在跑    → 发布者只有 map_server
#   两个都在跑   → 发布者 2 个 ← 冲突的确凿证据
echo ""
bold "──────────────── 0b. 定位栈互斥检查（抖动的头号嫌疑）────────"

node_present() { ros2 node list 2>/dev/null | grep -qx "/$1"; }
# 谁在发 /map（只列 PUBLISHER，不列订阅者）
map_publishers() {
  ros2 topic info /map -v 2>/dev/null | awk '
    /^Node name:/ { n=$3 }
    /^Endpoint type: PUBLISHER/ { if (n != "") print n }' | sort -u
}

LOC_CONFLICT=0
PUB_GMP=0; PUB_MS=0
node_present slam_gmapping && PUB_GMP=1
node_present map_server    && PUB_MS=1
MAP_PUBS="$(map_publishers)"
NPUB=$(printf '%s' "$MAP_PUBS" | grep -c . 2>/dev/null || echo 0)

if [ "$PUB_GMP" = 1 ] && [ "$PUB_MS" = 1 ]; then
  LOC_CONFLICT=1
  error "/map 有 2 个发布者 → SLAM 与 Nav2 正在【同时运行】，必须只留一套！"
  printf '%s\n' "$MAP_PUBS" | sed 's/^/       /'
elif [ "${NPUB:-0}" -gt 1 ] 2>/dev/null; then
  LOC_CONFLICT=1
  error "/map 有 $NPUB 个发布者 —— 只应该有一个（要么 gmapping，要么 map_server）"
  printf '%s\n' "$MAP_PUBS" | sed 's/^/       /'
fi

if [ "$LOC_CONFLICT" = 1 ]; then
  echo "     两者都会广播 map→odom、也都会往 /map 发地图："
  echo "       → RViz 每帧随机取其中一条 → 地图原地剧烈抖动、机器人位置乱跳"
  echo "     特别地：在 RViz 点过 \"2D Pose Estimate\" 之后会突然开始抖 ——"
  echo "       那个按钮发 /initialpose，gmapping 源码里【根本没有订阅它】，"
  echo "       是 amcl 收到后才开始发 map→odom，两条 TF 从这一刻打起来。"
  echo "     处理：建图阶段关掉 Nav2；导航阶段先关掉 SLAM。"
elif [ "$PUB_GMP" = 1 ]; then
  ok "/map 只由 slam_gmapping 发布（正常，建图阶段就该这样）"
elif [ "$PUB_MS" = 1 ]; then
  ok "/map 只由 map_server 发布（正常，导航阶段就该这样）"
elif [ "${NPUB:-0}" -eq 1 ]; then
  ok "/map 只有 1 个发布者：$MAP_PUBS"
else
  warn "/map 当前没有发布者 —— 建图和导航都没在跑（map 坐标系不存在）"
  echo "     建图：【终端 D】bash 05_run_robot.sh slam"
  echo "     导航：【终端 D】bash 05_run_robot.sh nav-rviz（需先有地图）"
fi

# ---- 1. /odom 自身的偏航抖动 ----------------------------------------------
echo ""
bold "──────────────── 1. 里程计（odom→base_footprint）─ 静止 ${SAMPLE_SEC}s ──"
ODY="$(sample_tf odom base_footprint RPY 3 "$SAMPLE_SEC")"
read -r N1 MIN1 MAX1 PP1 SD1 <<<"$(echo "$ODY" | stats)"
ODX="$(sample_tf odom base_footprint Translation 1 "$SAMPLE_SEC")"
read -r N2 MIN2 MAX2 PP2 SD2 <<<"$(echo "$ODX" | stats)"
ODYAW_PP_DEG=$(awk -v p="$PP1" -v d="$DEG" 'BEGIN{printf "%.2f", p*d}')
ODYAW_SD_DEG=$(awk -v s="$SD1" -v d="$DEG" 'BEGIN{printf "%.2f", s*d}')
ODX_PP_MM=$(awk -v p="$PP2" 'BEGIN{printf "%.1f", p*1000}')
printf "  样本数            : %s\n" "$N1"
printf "  偏航峰峰值        : %.4f rad  = %s°\n" "$PP1" "$ODYAW_PP_DEG"
printf "  偏航标准差        : %.4f rad  = %s°\n" "$SD1" "$ODYAW_SD_DEG"
printf "  x 位移峰峰值      : %s mm\n" "$ODX_PP_MM"

# ---- 2. map→odom 是否稳定 --------------------------------------------------
echo ""
bold "──────────────── 2. gmapping 修正（map→odom）─ 静止 ${SAMPLE_SEC}s ────"
MOY="$(sample_tf map odom RPY 3 "$SAMPLE_SEC")"
read -r N3 MIN3 MAX3 PP3 SD3 <<<"$(echo "$MOY" | stats)"
MOY_PP_DEG=$(awk -v p="$PP3" -v d="$DEG" 'BEGIN{printf "%.2f", p*d}')
printf "  样本数            : %s\n" "$N3"
printf "  偏航峰峰值        : %.4f rad  = %s°\n" "$PP3" "$MOY_PP_DEG"

# 关键判据：map→odom 是不是只在两组固定值之间来回跳？
MOX="$(sample_tf map odom Translation 1 "$SAMPLE_SEC")"
read -r NU VA PA VB PB COVER DIFF <<<"$(echo "$MOX" | two_cluster)"
printf "  x 的不同取值个数  : %s\n" "${NU:-0}"
printf "  取值分布 top2     : %s (%.1f%%) / %s (%.1f%%)  合计 %s%%\n" \
       "${VA:-?}" "${PA:-0}" "${VB:-?}" "${PB:-0}" "${COVER:-0}"
printf "  两组差值          : %s m\n" "${DIFF:-0}"
if [ "${N3:-0}" -lt 30 ] 2>/dev/null; then
  warn "样本太少（${N3:-0} 个）→ 判不了，请把 SAMPLE_SEC 调大或用默认 TF_HZ=30 重跑"
elif [ "${NU:-99}" -le 4 ] 2>/dev/null && [ "${COVER%.*}" -ge 60 ] 2>/dev/null \
   && awk -v d="${DIFF:-0}" 'BEGIN{exit !(d>0.05)}'; then
  error "map→odom 只在 $NU 组固定值之间交替（占 ${COVER}%，相差 ${DIFF} m，共 ${N3} 个样本）"
  echo "     ⇒ 典型的【两个广播者在抢同一条 TF 边】："
  echo "        ${VA}  和  ${VB}  两组值反复横跳，车静止时也这样。"
  echo "     ⇒ 直接原因见上面 0b 节（SLAM 与 Nav2/amcl 同时在跑）。"
  LOC_CONFLICT=1
elif [ "${NU:-0}" -gt 60 ] 2>/dev/null; then
  warn "map→odom 取值非常分散（$NU 个不同值）→ 不像冲突，更像里程计/匹配噪声（看第 1、3 节）"
else
  ok "map→odom 没有出现「两组值交替」的特征"
fi

# ---- 3. 直接问固件：motion.yaw / imu.yaw 各自漂不漂 -------------------------
echo ""
bold "──────────────── 3. 机器人内部（绕开 ROS）────────────────────"
if [ -z "$ROBOT_IP" ]; then
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  lip=$(ip -o -4 addr show dev "${dev:-eno2}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [ -n "$lip" ]; then
    info "未指定机器人 IP，扫描 ${lip%.*}.0/24 …"
    ROBOT_IP=$(seq 1 254 | xargs -P 48 -I{} sh -c \
      "curl -s -m 1 --noproxy '*' http://${lip%.*}.{}/api/status 2>/dev/null | grep -q '\"device_name\":\"Maturo_' && echo ${lip%.*}.{}" \
      2>/dev/null | head -1)
  fi
fi

MY_SER=""; IY_SER=""; VOLT=""; LVP=""
if [ -n "$ROBOT_IP" ]; then
  ok "机器人: $ROBOT_IP"
  for _i in 1 2 3 4 5 6 7 8; do
    s=$(curl -s -m 2 --noproxy '*' "http://$ROBOT_IP/api/status" 2>/dev/null)
    [ -z "$s" ] && break
    MY_SER="$MY_SER $(echo "$s" | grep -o '"motion":{[^}]*}' | grep -o '"yaw":[-0-9.]*' | head -1 | cut -d: -f2)"
    IY_SER="$IY_SER $(echo "$s" | grep -o '"imu":{[^}]*}'    | grep -o '"yaw":[-0-9.]*' | head -1 | cut -d: -f2)"
    VOLT=$(echo "$s" | grep -o '"voltage_v":[0-9.]*' | cut -d: -f2)
    LVP=$(echo "$s" | grep -o '"lidar_valid_points":[0-9]*' | cut -d: -f2)
    sleep 1.5
  done
else
  warn "没找到机器人（WiFi 断了吗？），跳过本节"
fi

if [ -n "${MY_SER// /}" ]; then
  read -r N4 MIN4 MAX4 PP4 SD4 <<<"$(echo "$MY_SER" | tr ' ' '\n' | grep -E '^-?[0-9]' | stats)"
  printf "  motion.yaw 峰峰值 : %s°   （固件里程计偏航，编码器积分）\n" "$(awk -v p="$PP4" 'BEGIN{printf "%.2f",p}')"
  printf "  motion.yaw 标准差 : %s°\n" "$(awk -v p="$SD4" 'BEGIN{printf "%.2f",p}')"
fi
if [ -n "${IY_SER// /}" ]; then
  read -r N5 MIN5 MAX5 PP5 SD5 <<<"$(echo "$IY_SER" | tr ' ' '\n' | grep -E '^-?[0-9]' | stats)"
  printf "  imu.yaw    峰峰值 : %s°   （IMU 偏航，有绝对基准）\n" "$(awk -v p="$PP5" 'BEGIN{printf "%.2f",p}')"
  printf "  imu.yaw    标准差 : %s°\n" "$(awk -v p="$SD5" 'BEGIN{printf "%.2f",p}')"
fi
[ -n "$VOLT" ] && printf "  电池电压         : %s V\n" "$VOLT"
[ -n "$LVP" ]  && printf "  有效雷达格数     : %s / 360\n" "$LVP"

# ---- 4. /scan 质量 ---------------------------------------------------------
echo ""
bold "──────────────── 4. /scan 数据质量 ──────────────────────────"
SCAN_F="/tmp/diag_scan_frame.yaml"
timeout 8 ros2 topic echo /scan --once --full-length >"$SCAN_F" 2>/dev/null
if [ -s "$SCAN_F" ]; then
  timeout 8 ros2 topic echo /scan --once 2>/dev/null | grep -E '^angle_|^range_|^scan_time|^time_increment' | sed 's/^/  /'
  read -r TOT ZEROS MAXRUN < <(grep -E '^- [0-9.eE+-]+$' "$SCAN_F" \
    | awk '{v=$2+0; n++; if(v==0){z++; c++; if(c>mx)mx=c} else c=0} END{printf "%d %d %d", n, z, mx}')
  if [ "${TOT:-0}" -gt 0 ]; then
    PZ=$(awk -v z="$ZEROS" -v n="$TOT" 'BEGIN{printf "%.0f", 100*z/n}')
    printf "  总点数            : %s\n" "$TOT"
    printf "  零值（无回波）    : %s 个 = %s%%\n" "$ZEROS" "$PZ"
    printf "  最长连续零段      : %s 个点（= %s°）\n" "$MAXRUN" "$MAXRUN"
    # 频率
    HZ=$(timeout 12 ros2 topic hz /scan 2>/dev/null | grep -m1 'average rate')
    [ -n "$HZ" ] && printf "  实际频率          : %s\n" "$(echo "$HZ" | sed 's/average rate: //; s/,.*//')"
  fi
else
  warn "没能抓到 /scan 一帧"
  ZEROS=0; PZ=0; MAXRUN=0; TOT=0
fi

# ---- 5. 判定 ---------------------------------------------------------------
echo ""
bold "════════════════ 结论 ════════════════"
VERDICT=0
if [ "$LOC_CONFLICT" = 1 ]; then
  error "0b 节的定位栈冲突还没解决 —— 先让 SLAM / Nav2 只留一套再复测"
  echo "     否则下面的数据全是被「两条 TF 打架」污染过的，没有参考价值。"
  VERDICT=9
fi
if [ "$VERDICT" != 0 ]; then
  :
elif awk -v p="${PP1:-0}" 'BEGIN{exit !(p*57.2957795 > 1.0)}'; then
  warn "里程计偏航在静止时抖（峰峰值 ${ODYAW_PP_DEG}°）→ 【odom 是抖动源头】"
  VERDICT=1
else
  ok "里程计偏航稳定（峰峰值 ${ODYAW_PP_DEG}°）"
fi
if [ "$VERDICT" = 0 ] && awk -v p="${PP3:-0}" 'BEGIN{exit !(p*57.2957795 > 1.0)}'; then
  warn "map→odom 在静止时也在变（峰峰值 ${MOY_PP_DEG}°）→ gmapping 修正在跳"
  VERDICT=2
fi
if [ "$VERDICT" = 0 ] && [ "${PZ:-0}" -ge 20 ]; then
  warn "扫描零值 ${PZ}%，最长连续 ${MAXRUN}° → 【雷达数据质量差】"
  VERDICT=3
fi

case "$VERDICT" in
  9) echo "  → 主因：定位栈冲突。杀掉其中一套再跑本脚本："
     echo "     建图阶段：关掉 Nav2（在启动它的终端按 Ctrl+C）"
     echo "     导航阶段：先关掉 SLAM，再起 Nav2 —— 此时 RViz 的 \"2D Pose Estimate\" 才有意义"
     echo "     查占用：ps -eo pid,etime,cmd | grep -E 'slam_|navigation2|component_container' | grep -v grep" ;;
  1) echo "  → 主因：里程计偏航噪声。修法见 README.md「Q25」：把 IMU 偏航并入 odom，"
     echo "     或在固件层给 odom_yaw_ 加 IMU 融合；临时缓解可把 gmapping 的"
     echo "     linearUpdate/angularUpdate 调小（注意 YAML 是死配置，须改源码重编）。" ;;
  2) echo "  → 主因：gmapping 修正跳变。检查 /scan 质量与 odom，再考虑调小更新阈值。" ;;
  3) echo "  → 主因：雷达数据。检查雷达视场是否被遮挡/污染、供电是否掉压、UART 是否丢包。" ;;
  *) echo "  → 静止时各项都稳。若 RViz 仍看着抖，多半是 RViz 显示设置问题（见 README Q24）。" ;;
esac
echo ""
info "提示：这个脚本必须在机器人静止时跑；动起来测没有意义。"
