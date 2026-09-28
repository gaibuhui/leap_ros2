#!/usr/bin/env bash
# =============================================================================
# LEAP_ROS 机器人 —— 运行脚本（上位机）
# =============================================================================
# 作用：加载 ROS 2 + 工作空间环境，并按需启动机器人各功能
# 用法（终端分工见 新手全流程指南.md）：
#   bash 05_run_robot.sh core                 # 【终端 A】核心链路：micro-ROS Agent + 机器人模型/TF
#   bash 05_run_robot.sh ekf                   # 【终端 A】核心链路 + IMU 融合 EKF（方向更稳，推荐）
#   bash 05_run_robot.sh reset                # 【终端 B】复位机器人（等价按 RESET 键）+ 自动同步 Agent IP
#   bash 05_run_robot.sh topics               # 【终端 B】查看话题 + Agent 会话状态
#   bash 05_run_robot.sh agent                # 只启动 micro-ROS Agent（日志写 /tmp/leap_ros_agent.log）
#   bash 05_run_robot.sh slam                 # 【终端 D】建图（gmapping）
#   bash 05_run_robot.sh slam-toolbox         # 【终端 D】建图（slam_toolbox）
#   bash 05_run_robot.sh nav / nav-rviz       # 【终端 D】导航（Nav2）
#   bash 05_run_robot.sh cam [地址]           # 视频流节点（地址不填则自动问机器人）
#   bash 05_run_robot.sh bringup              # 启动整机（含 socat + YDLIDAR，官方 bringup_all）
#   bash 05_run_robot.sh lidar / qtgui         # 雷达 / Qt 面板
#   bash 05_run_robot.sh rviz [配置.rviz]      # RViz（默认加载项目自带配置，话题已填好）
#
# 通用开关（可放任意位置）：
#   --force / -f    ① UDP :8888 已被旧 Agent 占用时，自动结束它再启动
#                      （常见场景：上次的终端被直接关掉，Agent 变成「孤儿进程」一直占着端口）
#                   ② SLAM 与 Nav2 同时在跑时，跳过「定位栈冲突」拦截强行启动
#
# ⚠ 定位栈互斥：SLAM(gmapping/slam_toolbox) 与 Nav2(amcl) 都广播 map→odom、
#   都往 /map 发地图，**同时跑必然导致 RViz 里地图/机器人剧烈抖动**。
#   本脚本在 slam/nav/nav-rviz 启动前会自动检测并拦截；用 topics 可随时查。
#
# 环境变量：
#   AGENT_VERBOSE=4    Agent 日志级别（默认 4=info；6=debug 会产生 30 秒 32MB 的日志，仅排障时用）
#   AGENT_LOG=...      Agent 日志文件（默认 /tmp/leap_ros_agent.log）
#   AGENT_PORT=8888    Agent 监听端口
# =============================================================================
set -uo pipefail

ROS_DISTRO_NAME="humble"
WS_DIR="${WS_DIR:-$HOME/leap_ros_ws}"

# ---- 解析参数：--force / -f 可放在任意位置，用于自动清理占用 8888 的旧 Agent ----
FORCE_KILL="${AGENT_FORCE:-0}"
ARGS=()
for _a in "$@"; do
  case "$_a" in
    --force|-f) FORCE_KILL=1 ;;
    *) ARGS+=("$_a") ;;
  esac
done
MODE="${ARGS[0]:-core}"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m $*"; }

AGENT_VERBOSE="${AGENT_VERBOSE:-4}"
AGENT_LOG="${AGENT_LOG:-/tmp/leap_ros_agent.log}"
AGENT_PORT="${AGENT_PORT:-8888}"
ROBOT_CACHE="${ROBOT_CACHE:-/tmp/leap_robot_ip}"   # 上次发现的机器人 IP，避免重复扫全网段

# ---- 本机 IP（取默认路由所在网卡，配网/复位时要用）--------------------------
my_iface_ip() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$dev" ] && ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 && return 0
  ip -o -4 addr show 2>/dev/null | awk '$2!="lo"{print $4}' | cut -d/ -f1 | head -1
}

# ---- 在局域网里找机器人（认 /api/status 里的 device_name=Maturo_*）---------
discover_robot() {
  local dev base neigh hits
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -z "$dev" ] && return 1
  base=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3)
  [ -z "$base" ] && return 1
  warn "未指定机器人 IP，正在扫描 $base.0/24 寻找机器人（约 5~10 秒）……" >&2
  hits=$(mktemp)
  # 主动 ping 一遍，把同网段在线设备填进 ARP 表（并行）
  seq 1 254 | xargs -P 64 -I{} sh -c "ping -c1 -W1 ${base}.{} >/dev/null 2>&1" 2>/dev/null
  # 只挑 ARP 里「真正在线」的条目 —— 必须排掉 FAILED/INCOMPLETE，
  # 否则会对着一堆不可达地址逐个 curl，慢到分钟级（实测踩过）
  neigh=$(ip neigh show dev "$dev" 2>/dev/null \
          | awk '$1 ~ /^[0-9]/ && $NF != "FAILED" && $NF != "INCOMPLETE" {print $1}')
  [ -z "$neigh" ] && { rm -f "$hits"; return 1; }
  printf '%s\n' "$neigh" | xargs -P 32 -I{} sh -c \
    'curl -s --noproxy "*" --connect-timeout 1 --max-time 2 "http://{}/api/status" 2>/dev/null | grep -q "\"device_name\":\"Maturo_" && echo "{}"' \
    > "$hits" 2>/dev/null
  if [ -s "$hits" ]; then head -1 "$hits"; rm -f "$hits"; return 0; fi
  rm -f "$hits"; return 1
}

# ---- 从 /api/status 的扁平 JSON 里取值（先屏蔽 wifi_comm_mode，避免误匹配 comm_mode）
jget() {
  sed 's/"wifi_comm_mode"/"wcm"/g' "$1" 2>/dev/null \
    | grep -o "\"$2\":\(\s*\)\?\(\"[^\"]*\"\|[0-9.]*\)" | head -1 | sed 's/^[^:]*://' | tr -d '"'
}

# ---- 找机器人：先看缓存（1 秒），缓存失效才扫全网段（~10 秒）-----------------
find_robot() {
  local ip
  if [ -s "$ROBOT_CACHE" ]; then
    ip=$(head -1 "$ROBOT_CACHE")
    if curl -s --noproxy '*' --connect-timeout 1 --max-time 3 "http://$ip/api/status" 2>/dev/null \
         | grep -q '"device_name":"Maturo_'; then
      echo "$ip"; return 0
    fi
  fi
  ip=$(discover_robot) || return 1
  echo "$ip" > "$ROBOT_CACHE" 2>/dev/null
  echo "$ip"
}

# ---- 问机器人要相机的视频流地址（/api/status 的 camera.stream_url）----------
robot_camera_url() {
  local ip="$1"
  [ -z "$ip" ] && return 1
  curl -s --noproxy '*' --connect-timeout 2 --max-time 6 "http://$ip/api/status" 2>/dev/null \
    | grep -o '"stream_url":"[^"]*"' | head -1 | cut -d'"' -f4
}

# ---- 定位栈探测：当前谁在发 map→odom ---------------------------------------
# SLAM（gmapping / slam_toolbox）与 Nav2 的 amcl **都会广播 map→odom**，
# 而且**都会往 /map 上发地图**。两套同时跑 → RViz 每帧随机取一条 →
# 地图原地剧烈抖动、机器人位置乱跳。这是本工程最容易撞上的坑。
locating_stack() {
  local s=""
  pgrep -f 'slam_gmapping|slam_toolbox' >/dev/null 2>&1 && s="$s SLAM"
  pgrep -f 'navigation2|nav2_bringup|component_container' >/dev/null 2>&1 && s="$s Nav2"
  printf '%s' "${s# }"
}

# 返回 0 = 无冲突；1 = 两套同时运行（并打印机理与处理办法）
loc_conflict_check() {
  local stack
  stack=$(locating_stack)
  case "$stack" in
    *SLAM*Nav2*|*Nav2*SLAM*)
      error "定位栈冲突：SLAM 与 Nav2 正在同时运行（$stack）"
      echo "     两者都会广播 map→odom、也都会往 /map 发地图，RViz 每帧随机取其中一条："
      echo "       → 表现为【地图原地剧烈抖动、机器人位置乱跳】"
      echo "       → 尤其在 RViz 点过 \"2D Pose Estimate\" 之后爆发：那个按钮发的是"
      echo "         /initialpose，而 gmapping 根本不订阅它（源码里没有这个订阅），"
      echo "         是 amcl 收到后才开始发 map→odom，于是从这一刻两条 TF 打起来。"
      echo ""
      echo "     处理：只保留一套 ——【建图阶段】关掉 Nav2；【导航阶段】先关掉 SLAM。"
      echo "     看是哪些进程："
      echo "       ps -eo pid,etime,cmd | grep -E 'slam_|navigation2|component_container' | grep -v grep"
      echo ""
      return 1
      ;;
  esac
  return 0
}

# ---- 等 Agent 会话建立（读 Agent 日志）-------------------------------------
# 返回 0=已建立  1=超时
wait_session() {
  local timeout="${1:-12}" i
  for i in $(seq 1 $((timeout * 2))); do
    grep -q 'session established' "$AGENT_LOG" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# ---- 会话未建立时给出一致的下一步指引 ---------------------------------------
hint_no_session() {
  echo ""
  echo -e "\033[1;33m──────────────────────────────────────────────────────────\033[0m"
  warn "机器人还没连上 Agent —— 原因和下一步："
  echo "   已知固件行为：机器人【一旦连上过 Agent，就不会再自动重连】。"
  echo "   所以 Agent 后启动 / 重启过 / 换过端口，都必须复位机器人。"
  echo ""
  echo -e "   \033[1;37m处理：按一下主控板的 RESET 键；或在【终端 B】执行：\033[0m"
  echo -e "         \033[1;37mbash 05_run_robot.sh reset\033[0m"
  echo ""
  echo "   复位后本终端会自动继续，无需重启本命令。"
  echo -e "\033[1;33m──────────────────────────────────────────────────────────\033[0m"
}

# ---- 找出占用 Agent 端口的进程 PID（找不到则输出空）------------------------
port_owner_pid() {
  ss -lunp 2>/dev/null | awk -v pat=":$AGENT_PORT " \
    '$0 ~ pat { if (match($0, /pid=[0-9]+/)) { print substr($0, RSTART+4, RLENGTH-4); exit } }'
}

# ---- 端口被占用时的处理 -----------------------------------------------------
# 关键区别：
#   * 还开着的终端 → 提示去那个终端 Ctrl+C
#   * 孤儿进程（原始终端已关闭，父进程变成 1/systemd）→ Ctrl+C 找不到，只能 kill
#     （本套件实测踩过：-v6 调试残留下来的 Agent 跑了 24 分钟一直占着 8888）
# FORCE_KILL=1（命令行 --force）时由本脚本直接结束旧进程。
free_agent_port() {
  local pid ppid pcomm orphan i
  pid=$(port_owner_pid)
  [ -z "$pid" ] && return 0

  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  pcomm=$(ps -o comm= -p "${ppid:-0}" 2>/dev/null)

  # 孤儿判据：父进程变成 init(1) 或用户会话的 systemd --user
  # （不能用 tty 字段判断：实测孤儿进程的 tty 仍显示 pts/N，会误判）
  orphan=0
  if [ "$ppid" = "1" ]; then
    orphan=1
  elif [ -n "$pcomm" ] && [ "$pcomm" = "systemd" ]; then
    orphan=1
  fi

  error "UDP :$AGENT_PORT 已被占用"
  error "占用者：PID $pid  (已运行 $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '))"
  ps -o cmd= -p "$pid" 2>/dev/null | cut -c1-100 | sed 's/^/         /' >&2

  if [ "$FORCE_KILL" != "1" ]; then
    if [ "$orphan" = "1" ]; then
      error "这是【孤儿进程】：当初启动它的终端已经关闭（父进程=$ppid/$pcomm）"
      error "在这种情况下去终端按 Ctrl+C 是找不到它的，请直接结束它："
      echo  "         kill $pid" >&2
    else
      error "请到 PID $pid 所在的那个终端按 Ctrl+C；也可以直接：  kill $pid"
    fi
    echo "     或让本脚本代劳：  bash 05_run_robot.sh $MODE --force" >&2
    return 1
  fi

  warn "--force 生效 → 结束旧 Agent (PID $pid)"
  kill "$pid" 2>/dev/null
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "普通信号无效 → 强制 KILL -9"
    kill -9 "$pid" 2>/dev/null
    sleep 1
  fi
  if ss -lun 2>/dev/null | grep -q ":$AGENT_PORT "; then
    error "端口仍未释放，请手动排查：ss -lunp | grep :$AGENT_PORT"
    return 1
  fi
  ok "端口 :$AGENT_PORT 已释放"
  warn "旧 Agent 一退出，机器人那边的会话就断了；而固件不会自动重连。"
  warn "→ 新 Agent 启动后若 12 秒内没建立会话，请执行：bash 05_run_robot.sh reset"
  echo ""
  return 0
}

# ---- 加载环境 ---------------------------------------------------------------
# 重要：ROS 2 及其工作空间生成的 setup.bash 都直接引用未定义的 $AMENT_TRACE_SETUP_FILES，
#       本脚本开启了 set -u（nounset），source 会立即终止整个脚本（exit 127）。
#       因此 source 期间临时关闭 nounset。
if [ -f "/opt/ros/$ROS_DISTRO_NAME/setup.bash" ]; then
  set +u
  # shellcheck disable=SC1090
  source "/opt/ros/$ROS_DISTRO_NAME/setup.bash"
  set -u
else
  error "未找到 ROS 2 $ROS_DISTRO_NAME → 请先执行 setup/01_install_ros2_humble.sh"
  exit 1
fi
if [ -f "$WS_DIR/install/setup.bash" ]; then
  set +u
  # shellcheck disable=SC1090
  source "$WS_DIR/install/setup.bash"
  set -u
else
  error "工作空间未编译 → 请先执行 setup/02_build_workspace.sh"
  exit 1
fi
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"

case "$MODE" in
  core)
    # ---------------------------------------------------------------------
    # 【新手推荐】核心链路：micro-ROS Agent + 机器人模型/TF
    #
    # 为什么不直接跑官方的 bringup_all.launch.py？
    #   官方那个文件里还包含 socat(UDP 8889 → /dev/lidar) 和 YDLIDAR 驱动，
    #   它们是给「外接独立 YD 激光雷达」准备的；而本套件的雷达接在主控板上，
    #   数据已经由主控通过 micro-ROS 的 /scan 话题传过来，所以这两个都不需要，
    #   且 socat 需要 root 权限（官方文件里硬编码了 sudo 密码，在你机器上会报错）。
    #
    # 为什么不直接跑官方 bringup_all.launch.py？
    #   官方文件里还包含 socat(UDP 8889 → /dev/lidar) 和 YDLIDAR 驱动，是给「外接独立
    #   YD 激光雷达」准备的；本套件雷达接在主控板上，数据已由主控经 micro-ROS 的
    #   /scan 话题传来，所以都不需要，且 socat 需要 root（官方文件硬编码了 sudo 密码）。
    info "启动核心链路：micro-ROS Agent + 机器人模型/TF"
    info "（雷达数据由主控经 micro-ROS 的 /scan 话题提供，无需 socat）"

    free_agent_port || exit 1

    # Agent 日志写文件：-v6 直接打到终端会 30 秒产出 32MB，把终端刷死
    : > "$AGENT_LOG" 2>/dev/null
    ros2 run micro_ros_agent micro_ros_agent udp4 --port "$AGENT_PORT" -v"$AGENT_VERBOSE" \
      >"$AGENT_LOG" 2>&1 &
    AGENT_PID=$!
    # 退出时一并清理后台的 Agent，避免残留占用端口
    cleanup() { kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null; }
    trap cleanup EXIT INT TERM

    info "micro-ROS Agent 已后台启动 (PID $AGENT_PID, UDP :$AGENT_PORT)"
    info "Agent 日志已落盘：$AGENT_LOG   （本终端不再刷屏；实时看：tail -f $AGENT_LOG）"
    info "等待机器人连接（最多 12 秒）……"

    if wait_session 12; then
      ok "机器人已连接 —— Agent 会话已建立"
      grep -m1 'session established' "$AGENT_LOG" | sed 's/^/      /'
    else
      hint_no_session
      info "继续启动机器人模型与 TF；会话建立后话题会自动出现"
    fi

    ros2 launch xuegecar_bringup xuegecar_bringup.launch.py
    ;;
  ekf|fusion)
    # ---------------------------------------------------------------------
    # 核心链路 + IMU 融合 EKF（与 core 只差一条 TF 的归属）
    #
    # 问题：固件的里程计偏航是「纯轮速差积分」（motion_controller.cpp:
    #       odom_yaw_ += local_vw*dt），轮子打滑或轮距不准就快速发散；
    #       而固件其实已经把 IMU 偏航算好了，却从没喂进里程计。
    #
    # 做法：robot_localization 做互补融合 —— 轮子给「前进速度 vx」，
    #       陀螺给「偏航角速度 vyaw」，位置/朝向由 EKF 自己积分。
    #       固件那份被污染的 x/y/yaw 一概不用。
    #
    # ⚠ 关键：odom→base_footprint 这条 TF 从此由 EKF 广播，
    #   所以底盘的广播必须关掉（publish_tf:=false）。两边同时发会让机器人
    #   在 RViz 里来回跳 —— 和 SLAM/Nav2 抢 map→odom 是同一类问题。
    # ---------------------------------------------------------------------
    info "启动核心链路 + IMU 融合 EKF"
    info "（odom→base_footprint 改由 EKF 广播；底盘侧该 TF 已关闭）"

    free_agent_port || exit 1

    # Agent 日志写文件：-v6 直接打到终端会 30 秒产出 32MB，把终端刷死
    : > "$AGENT_LOG" 2>/dev/null
    ros2 run micro_ros_agent micro_ros_agent udp4 --port "$AGENT_PORT" -v"$AGENT_VERBOSE" \
      >"$AGENT_LOG" 2>&1 &
    AGENT_PID=$!
    EKF_PID=""
    # 退出时一并清理后台的 Agent 与 EKF，避免残留占用端口
    cleanup() {
      kill "$AGENT_PID" 2>/dev/null || true
      if [ -n "${EKF_PID:-}" ]; then kill "$EKF_PID" 2>/dev/null || true; fi
      wait "$AGENT_PID" 2>/dev/null || true
      if [ -n "${EKF_PID:-}" ]; then wait "$EKF_PID" 2>/dev/null || true; fi
    }
    trap cleanup EXIT INT TERM

    info "micro-ROS Agent 已后台启动 (PID $AGENT_PID, UDP :$AGENT_PORT)"
    info "Agent 日志已落盘：$AGENT_LOG   （实时看：tail -f $AGENT_LOG）"
    info "等待机器人连接（最多 12 秒）……"

    if wait_session 12; then
      ok "机器人已连接 —— Agent 会话已建立"
      grep -m1 'session established' "$AGENT_LOG" | sed 's/^/      /'
    else
      hint_no_session
      info "继续启动；/imu 到位后 EKF 才会开始输出 TF"
    fi

    info "启动 IMU 协方差修正 + EKF 融合（日志见本终端）"
    info "提示：固件 /imu 的协方差是 -1（=无效），修正节点会补成有效值发到 /imu/data"
    ros2 launch xuegecar_navigation2 ekf_localization.launch.py &
    EKF_PID=$!
    sleep 2

    info "启动机器人模型（publish_tf:=false，TF 交给 EKF）"
    info "验证：另开终端跑  bash 05_run_robot.sh topics  应能看到 /odometry/filtered 和 /imu/data"
    ros2 launch xuegecar_bringup xuegecar_bringup.launch.py publish_tf:=false
    ;;
  bringup)
    info "启动整机（官方 bringup_all）：socat + micro-ROS Agent + YDLIDAR + 底盘"
    info "注意：socat 需要 root，若未配置免密会报错（不影响 /scan）"
    info "如需免密配置：bash 06_setup_lidar_socat.sh"
    exec ros2 launch xuegeros_demo bringup_all.launch.py
    ;;
  slam|gmapping)
    loc_conflict_check || { error "如确要继续，加 --force"; exit 1; }
    info "启动 gmapping 建图"
    exec ros2 launch slam_gmapping slam_gmapping.launch.py
    ;;
  slam-toolbox)
    loc_conflict_check || { error "如确要继续，加 --force"; exit 1; }
    info "启动 slam_toolbox"
    exec ros2 launch slam_toolbox online_async_launch.py
    ;;
  nav|navigation)
    loc_conflict_check || { error "如确要继续，加 --force"; exit 1; }
    info "启动 Nav2 导航（需先有地图）"
    exec ros2 launch xuegecar_navigation2 navigation2.launch.py
    ;;
  nav-rviz)
    loc_conflict_check || { error "如确要继续，加 --force"; exit 1; }
    info "启动 Nav2 导航 + RViz"
    exec ros2 launch xuegecar_navigation2 navigation2_rviz.launch.py
    ;;
  cam|camera)
    # 相机地址优先级：命令行参数 > 问机器人（/api/status 的 camera.stream_url）> yaml 默认值
    # 用法：bash 05_run_robot.sh cam [http://<相机IP>:81/]
    CAM_URL="${ARGS[1]:-}"
    if [ -n "$CAM_URL" ]; then
      info "使用命令行指定的相机地址：$CAM_URL"
    else
      R_IP=$(find_robot 2>/dev/null) || R_IP=""
      CAM_URL=$(robot_camera_url "$R_IP") || CAM_URL=""
      if [ -n "$CAM_URL" ]; then
        info "从机器人 ${R_IP} 自动发现相机：$CAM_URL"
      else
        warn "没能从机器人问出相机地址（机器人没在线？）"
        warn "将使用 yaml 里的默认值 —— 那多半是作者的地址，会连不上"
        echo "     也可以手动指定：bash 05_run_robot.sh cam http://<相机IP>:81/"
      fi
    fi
    echo ""
    echo -e "   \033[1;37m浏览器直接看画面：\033[0m ${CAM_URL:-<yaml 默认值>}"
    echo "   ⚠ 相机要预热，【约 8~10 秒后】才会出第一帧，别以为没反应"
    echo ""
    info "启动摄像头视频流节点（HTTP/MJPEG）"
    if [ -n "$CAM_URL" ]; then
      exec ros2 launch xuegecar_camera http_video_publisher.launch.py "url:=$CAM_URL"
    else
      exec ros2 launch xuegecar_camera http_video_publisher.launch.py
    fi
    ;;
  lidar)
    info "单独启动 YDLIDAR 雷达"
    exec ros2 launch ydlidar_ros2_driver ydlidar_launch.py
    ;;
  agent)
    info "单独启动 micro-ROS Agent (UDP :$AGENT_PORT) —— 前台运行，Ctrl+C 退出"
    info "日志同时写入 $AGENT_LOG"
    free_agent_port || exit 1
    : > "$AGENT_LOG" 2>/dev/null
    ros2 run micro_ros_agent micro_ros_agent udp4 --port "$AGENT_PORT" -v"$AGENT_VERBOSE" 2>&1 \
      | tee "$AGENT_LOG"
    ;;
  rviz)
    # 裸 rviz2 是空白配置：Displays 里所有话题都是空的 → LaserScan 直接红字 Error。
    # 这里默认加载项目自带的配置，已经在里面填好了 /scan /odom /map。
    # 用法：bash 05_run_robot.sh rviz [自定义.rviz]
    RVCFG="${ARGS[1]:-}"
    if [ -z "$RVCFG" ]; then
      for c in \
        "$HOME/leap_ros_ws/src/xuegecar_cartographer/rviz/xuegecar_cartographer.rviz" \
        "$HOME/leap_ros_ws/src/xuegecar_cartographer/config/cartographer.rviz" \
        "$HOME/leap_ros_ws/src/xuegecar_navigation2/rviz/xuege_navigation2.rviz"
      do
        [ -f "$c" ] && { RVCFG="$c"; break; }
      done
    fi
    if [ -n "$RVCFG" ] && [ -f "$RVCFG" ]; then
      info "启动 RViz2，加载配置：$RVCFG"
    elif [ -n "$RVCFG" ]; then
      error "找不到配置：$RVCFG"
      exit 1
    else
      warn "没找到项目自带的 .rviz 配置 → 启动空白 RViz，需要手动填 Topic"
      RVCFG=""
    fi
    if [ -n "$RVCFG" ]; then
      exec rviz2 -d "$RVCFG"
    else
      exec rviz2
    fi
    ;;
  topics)
    echo ""
    echo "──────── Agent 会话状态 ────────────────────────────────────"
    OWNER_PID=$(port_owner_pid)
    OWNER_PPID=""
    if [ -n "$OWNER_PID" ]; then
      ok "micro-ROS Agent 正在监听 UDP :$AGENT_PORT (PID $OWNER_PID)"
      OWNER_PPID=$(ps -o ppid= -p "$OWNER_PID" 2>/dev/null | tr -d ' ')
      if [ "$OWNER_PPID" = "1" ] \
         || [ "$(ps -o comm= -p "${OWNER_PPID:-0}" 2>/dev/null)" = "systemd" ]; then
        warn "但它是孤儿进程（父进程 $OWNER_PPID，原始终端已关闭）"
        echo "     → 想重启 Agent 只能先：kill $OWNER_PID  （或 bash 05_run_robot.sh core --force）"
      fi
    elif pgrep -f 'micro_ros_agent udp4' >/dev/null 2>&1; then
      warn "有 micro_ros_agent 进程，但它没有监听 :$AGENT_PORT（可能跑在别的端口上）"
    else
      error "没有 micro-ROS Agent 在运行"
      echo "     → 先在【终端 A】执行：bash 05_run_robot.sh core"
    fi
    if [ -f "$AGENT_LOG" ]; then
      if grep -q 'session established' "$AGENT_LOG" 2>/dev/null; then
        ok "Agent 会话已建立："
        grep -m1 'session established' "$AGENT_LOG" | sed 's/^/        /'
      else
        warn "Agent 日志中没有 'session established' → 机器人还没连上"
        echo "     → 按主控板 RESET 键；或在【终端 B】执行：bash 05_run_robot.sh reset"
      fi
    else
      warn "找不到 $AGENT_LOG（Agent 不是用本脚本启动的，或还没启动过）"
    fi

    echo ""
    echo "──────── 当前话题 ──────────────────────────────────────────"
    ros2 topic list -t

    echo ""
    echo "──────── 机器人话题检查 ────────────────────────────────────"
    TL=$(ros2 topic list 2>/dev/null)
    MISS=0
    for t in /scan /odom /imu /battery_state; do
      if echo "$TL" | grep -qx "$t"; then ok "$t"; else warn "$t 缺失"; MISS=1; fi
    done
    if [ "$MISS" -eq 1 ]; then
      echo ""
      warn "机器人话题缺失 ⇒ 十有八九是 Agent 会话没建立（见上面第 1 节）"
      echo "     注意：/odom 即使没有机器人也可能出现（bringup 只订阅它，不发布），"
      echo "           所以别只看 /odom，要看 /scan /imu /battery_state。"
    fi

    echo ""
    echo "──────── 定位栈（谁在发 map→odom）──────────────────────────"
    LSTACK=$(locating_stack)
    if [ -z "$LSTACK" ]; then
      echo "     当前没有 SLAM / Nav2 在运行（map 坐标系不存在）"
    else
      echo "     正在运行：$LSTACK"
    fi
    if ! loc_conflict_check; then
      warn "↑ 这就是地图/机器人抖动的直接原因，先解决它再谈其它"
    fi
    # /map 的发布者数量 —— 两个发布者同样会让 RViz 的 Map 显示来回跳
    if ros2 topic list 2>/dev/null | grep -qx '/map'; then
      NMP=$(ros2 topic info /map 2>/dev/null | awk -F': ' '/Publisher count/{print $2}')
      if [ "${NMP:-1}" -gt 1 ] 2>/dev/null; then
        warn "/map 有 $NMP 个发布者（gmapping 的实时图 + map_server 的静态图）"
        echo "     → RViz 的 Map 显示会在两张地图之间切换，看起来也在抖"
        echo "       看是谁：ros2 topic info /map -v | grep -A2 'Node name'"
      else
        ok "/map 发布者数量正常（${NMP:-1}）"
      fi
    fi
    echo ""
    ;;
  reset)
    # ---------------------------------------------------------------------
    # 远程复位机器人 = 等价于按一下主控板的 RESET 键
    # 顺带把「micro-ROS Agent IP」同步为本机 IP —— 这是最高频的故障点
    # 用法：bash 05_run_robot.sh reset [机器人IP]
    # ---------------------------------------------------------------------
    MYIP=$(my_iface_ip)
    ROBOT_IP="${ARGS[1]:-}"
    if [ -z "$ROBOT_IP" ]; then
      ROBOT_IP=$(discover_robot) || { error "没找到机器人 → 确认已上电、且连的是同一个 WiFi"; exit 1; }
    fi
    info "机器人 $ROBOT_IP      本机 ${MYIP:-<未知>}"

    TMP=$(mktemp)
    curl -s --noproxy '*' --connect-timeout 4 --max-time 8 "http://$ROBOT_IP/api/status" -o "$TMP" 2>/dev/null
    if ! grep -q 'device_name' "$TMP" 2>/dev/null; then
      error "读不到 http://$ROBOT_IP/api/status → 机器人不在线或 IP 不对"
      echo "     先看它是否在线：【终端 E】bash 09_preflight.sh"
      rm -f "$TMP"; exit 1
    fi
    CUR_MODE=$(jget "$TMP" comm_mode); CUR_AIP=$(jget "$TMP" microros_agent_ip)
    CUR_PORT=$(jget "$TMP" microros_agent_port); UP=$(jget "$TMP" uptime_ms)
    info "机器人当前：mode=$CUR_MODE  agent=$CUR_AIP:$CUR_PORT  uptime=$(( ${UP:-0} / 1000 ))s"

    NEW_AIP="${MYIP:-$CUR_AIP}"
    NEW_PORT="${CUR_PORT:-8888}"
    if [ "$NEW_AIP" != "$CUR_AIP" ]; then
      warn "Agent IP 不一致（$CUR_AIP → $NEW_AIP），一并更正为本机 IP"
    fi

    R=$(curl -s --noproxy '*' -X POST "http://$ROBOT_IP/api/runtime-config" \
          -H 'Content-Type: application/x-www-form-urlencoded' \
          --data "comm_mode=micro_ros&microros_agent_ip=$NEW_AIP&microros_agent_port=$NEW_PORT" \
          --connect-timeout 5 --max-time 12 2>&1)
    echo "     机器人回应：$R"
    case "$R" in
      *'"ok":true'*) ok "已下发复位指令（重启约 10~20 秒）" ;;
      *) warn "复位指令可能未生效（上方回应不是 {\"ok\":true,...}）" ;;
    esac
    rm -f "$TMP"

    info "等待 18 秒后检查会话……"
    sleep 18
    if [ -f "$AGENT_LOG" ] && grep -q 'session established' "$AGENT_LOG" 2>/dev/null; then
      ok "Agent 会话已建立 —— 【终端 B】执行 bash 05_run_robot.sh topics 即可看到 /scan"
    elif ros2 topic list 2>/dev/null | grep -qx '/scan'; then
      ok "已连通 —— /scan 等机器人话题已出现"
    else
      hint_no_session
    fi
    ;;
  qtgui)
    info "启动 Qt GUI 控制面板"
    exec ros2 launch xuegecar_qt_gui xuegecar_qt_gui.launch.py
    ;;
  *)
    echo "未知模式: $MODE"
    awk '/^# 用法/,/^# ={10,}/' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
