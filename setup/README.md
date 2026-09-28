# LEAP_ROS 机器人 —— Linux 环境配置指南

> 适用：Ubuntu 22.04 (jammy) x86_64
> 目标机器人：LEAP_ROS / 学哥ROS 二驱智能车（ESP32-S3 主控 + ROS 2 上位机）
>
> **环境已装好，想直接连机器人开跑？** → 看 [`新手全流程指南.md`](./新手全流程指南.md)
> **想调某个参数，不知道在哪改？** → 看 [`参数调参索引.md`](./参数调参索引.md)
> **本文件**讲的是环境安装、架构原理和故障排查。

---

## 〇、当前部署状态（截至本次配置）

| 项目 | 状态 | 说明 |
|------|------|------|
| ROS 2 Humble 本体 | ✅ 已安装 | `/opt/ros/humble`（桌面版 + 全部功能依赖） |
| ROS 2 工作空间 | ✅ **已编译通过** | `~/leap_ros_ws` —— **13 个包全部成功**，`install/` 已生成 |
| YDLidar-SDK | ✅ 已安装 | `~/.local`（`ydlidar_ros2_driver` 的必需依赖，见 Q14） |
| rosdep 源 | ✅ 已切国内镜像 | 清华 TUNA，绕过 `raw.githubusercontent.com` 429（出了问题跑 `sudo bash 07_fix_rosdep.sh`） |
| ESP-IDF v5.5.3 | ✅ 已安装 | `~/esp/esp-idf`（含全部 23 个 git 子模块） |
| ESP-IDF esp32s3 工具链 | ✅ 已安装 | `~/.espressif`（xtensa-gcc 14.2.0、esptool 4.12.0） |
| 固件工程 | ✅ 已部署并**编译通过** | `~/leap_firmware/`（leap_low_v1 + leap_cam，均产出 `merged-binary.bin`） |
| 串口权限 / udev | ✅ 已配置 | 用户已在 `dialout` 组，`99-robot-serial.rules` 已写入 |
| pip 镜像 | ✅ 已配置 | 清华 TUNA（`~/.config/pip/pip.conf`） |
| 运行前预检脚本 | ✅ 已就绪 | `09_preflight.sh`（查本机 IP / 端口 / 相机 / 连通性） |
| 环境自检 | ✅ **PASS 37 / WARN 3 / FAIL 0** | 剩余 WARN = 未接硬件 + 可选的官方扩展包 |

> **下一步做什么**：环境这边已经全部就绪，剩下的是**硬件侧**的事 ——
> 烧固件、配网、连机器人。请照着 [`新手全流程指南.md`](./新手全流程指南.md) 走一遍。
>
> ```bash
> newgrp dialout              # 让串口组权限生效（或直接注销重登）
> cd /media/lixin/新加卷/robot/setup
> bash 09_preflight.sh        # 预检：会打印你电脑的 IP（配网要用）
> ```
>
> 本环境的安全策略禁止提权（`NoNewPrivs=1`），所以所有 `sudo` 操作都是由脚本
> 在你的终端里完成的。上述成果均已**经过真实编译 / 运行验证**，不是纸面推断。

---

## 一、系统架构总览

这套机器人是 **"下位机 + 上位机"** 双层结构，需要配 **两套独立环境**：

```
┌─────────────────────────────────────────────────────────────┐
│  上位机（你的 Linux 电脑）                                    │
│  Ubuntu 22.04 + ROS 2 Humble                                 │
│                                                              │
│   ┌──────────────┐   ┌──────────────┐   ┌───────────────┐   │
│   │ micro-ROS    │   │ 雷达驱动      │   │ 建图/导航      │   │
│   │ Agent (UDP)  │   │ ydlidar      │   │ gmapping/Nav2 │   │
│   └──────┬───────┘   └──────┬───────┘   └───────────────┘   │
└──────────┼──────────────────┼───────────────────────────────┘
           │ UDP :8888        │ UDP :8889 (socat→/dev/lidar)
           │                  │
┌──────────┼──────────────────┼───────────────────────────────┐
│  下位机（车上 ESP32-S3）    │                                │
│   ┌──────▼───────┐   ┌──────▼───────┐                        │
│   │ 主控固件      │   │ 雷达          │                        │
│   │ leap_low_v1  │   │ (串口转 UDP)  │                        │
│   │ 电机/里程计   │   └──────────────┘                        │
│   │ IMU/超声波    │                                           │
│   └──────────────┘                                           │
│         ▲                                                     │
│         │ WiFi (MJPEG 视频流 :81)                             │
│   ┌─────┴────────┐                                            │
│   │ 图传固件      │                                            │
│   │ leap_cam     │                                            │
│   └──────────────┘                                            │
└──────────────────────────────────────────────────────────────┘
```

**两套环境互不干扰，建议在不同终端中分别使用：**

| 环境 | 用途 | 安装位置 | 是否需要 sudo |
|------|------|----------|---------------|
| **ROS 2 Humble** | 上位机：建图、导航、可视化 | `/opt/ros/humble` | 是 |
| **ESP-IDF v5.5.3** | 下位机：编译烧录 ESP32-S3 固件 | `~/esp/esp-idf` | 否 |

> ⚠️ **重要**：ROS 2 与 ESP-IDF 都会修改 `PYTHONPATH` 等环境变量，
> **不要在同一终端同时 source 两者的环境**，否则会出现 Python 模块冲突。

---

## 二、目录约定

本指南使用以下目录（已由脚本自动部署）：

```
~/leap_ros_ws/                  # ROS 2 工作空间（上位机）
├── src/
│   ├── camsense_lidar/         # 串口雷达驱动
│   ├── ldlidar_stl_ros2/       # LD 系列雷达驱动
│   ├── ydlidar_ros2_driver/    # YDLIDAR 驱动（默认使用）
│   ├── micro_ros_agent/        # micro-ROS Agent（与下位机通信）
│   ├── xuegecar_bringup/       # 底盘 bringup
│   ├── xuegecar_camera/        # 摄像头视频流
│   ├── xuegecar_cartographer/  # Cartographer 建图
│   ├── xuegecar_description/   # URDF 模型
│   ├── xuegecar_navigation2/   # Nav2 导航配置
│   ├── xuegecar_qt_gui/        # Qt 控制面板
│   ├── slam_gmapping/          # gmapping 建图
│   └── xuegeros_demo/          # 综合启动
├── build/  install/  log/      # 编译产物

~/leap_firmware/                # ESP32-S3 固件工程（下位机）
├── leap_low_v1/                # 主控固件（电机/里程计/IMU/雷达/micro-ROS）
└── leap_cam/                   # WiFi 图传固件（MJPEG 视频流）

~/esp/esp-idf/                  # ESP-IDF v5.5.3 源码
~/.espressif/                   # ESP-IDF 工具链（xtensa 编译器 + Python 环境）
```

---

## 三、快速开始

### 步骤 0：确认前置条件

```bash
# 系统版本（必须是 22.04）
lsb_release -ds

# 网络（ROS 源与乐鑫镜像可达）
curl -sS -m 6 -o /dev/null -w "%{http_code}\n" http://packages.ros.org/ros2/ubuntu/dists/jammy/Release
```

### 步骤 1：安装 ROS 2 Humble（需 sudo，约 1.5~2.5 GB）

```bash
cd /media/lixin/新加卷/robot/setup
bash 01_install_ros2_humble.sh
```

安装内容：
- ROS 2 Humble 桌面版（含 RViz2、rqt）
- Nav2 导航栈、Cartographer、gmapping 依赖
- robot_localization、tf2 全家桶
- micro-ROS 相关消息与 FastRTPS 组件
- Python 依赖（opencv、numpy、PIL）
- **串口权限**：当前用户加入 `dialout` 组 + udev 规则
- **环境变量**：写入 `~/.bashrc`

> 如果 `curl` 下载 ROS GPG key 超时，脚本会自动回退到 Gitee 镜像。

### 步骤 2：安装 ESP-IDF v5.5.3（无需 sudo）

```bash
bash 03_install_espidf.sh
```

安装内容：
- ESP-IDF v5.5.3 源码 → `~/esp/esp-idf`
- esp32s3 工具链 → `~/.espressif`
- 使用 **乐鑫国内镜像** `dl.espressif.cn`（约 8 MB/s，远快于官方源）
- 在 `~/.bashrc` 中注册 `get_idf` 别名

> ⚠️ 脚本会检测 `python3-venv`。若系统缺失该包，需先执行：
> `sudo apt install -y python3-venv`
> （如果已安装 `virtualenv` 也可正常工作）

### 步骤 3：编译 ROS 2 工作空间

```bash
bash 02_build_workspace.sh
```

首次编译约 3~8 分钟。编译成功后会自动提示如何加载工作空间。

### 步骤 4：环境自检

```bash
bash 99_check_env.sh
```

逐项检查并输出 `PASS / WARN / FAIL` 汇总。

---

## 四、运行机器人

> 📖 **第一次连接机器人？请直接看 [`新手全流程指南.md`](./新手全流程指南.md)**
> —— 从接线、烧录、配网到跑起来的顺序化手册，含每个环节的判断标准。
> 该文档开头有一张 **终端分工表**（A 链路／B 检查／C 遥控／D 建图导航／E 烧录），
> **每个命令都标明该在哪个终端执行** —— 照着开终端就不会互相干扰。
> 本节只做命令速查。

### 4.0 运行前预检

```bash
# 【终端 B】打印本机 IP（配网要填）、检查环境/串口/端口/相机 + 自动发现机器人
bash 09_preflight.sh

# 也可以直接指定机器人 IP
bash 09_preflight.sh 192.168.0.244
```

### 4.1 烧录固件（下位机）

```bash
# 查看可用串口
bash 04_flash_firmware.sh --list

# 烧录主控固件（电机/里程计/IMU/雷达）—— 自动探测串口
bash 04_flash_firmware.sh low

# 烧录 WiFi 图传固件
bash 04_flash_firmware.sh cam

# 指定串口 + 烧完打开串口监视
bash 04_flash_firmware.sh low --port /dev/ttyUSB0 --monitor
```

> ESP32-S3 原生 USB-CDC 设备通常为 `/dev/ttyACM0`；
> 使用 CH340/CP210x 转串口芯片时通常为 `/dev/ttyUSB0`（国产板大多如此）。
>
> **一块一块烧**：两块板同时插着会分不清串口，容易烧错固件。
>
> **串口权限**：脚本会在编译前检查串口可读写性，失败立即报错并给出修复指引。
> 若提示 `不可读写`，跑 `sudo bash 11_fix_serial_perm.sh` 一键修复
> （常见根因：udev 规则只匹配了 CH340 的 `1a86:7523`，而实际芯片是 `1a86:7522`）。

### 4.2 启动机器人（上位机）

```bash
# 【终端 A】核心链路：micro-ROS Agent + 机器人模型/TF（零 sudo、零报错，日志写 /tmp/leap_ros_agent.log）
bash 05_run_robot.sh core

# 【终端 B】★ 一键复位机器人（等价按 RESET 键）+ 自动同步 Agent IP
bash 05_run_robot.sh reset

# 【终端 B】看 Agent 会话状态 + 话题列表 + 关键话题检查
bash 05_run_robot.sh topics

# 【终端 A】官方整机（含 socat + YDLIDAR，仅外接独立 YD 雷达时需要）
bash 05_run_robot.sh bringup

# 【终端 D】建图 / 导航（需先有地图）/ 视频流 / RViz / Qt 面板
bash 05_run_robot.sh slam
bash 05_run_robot.sh nav-rviz
bash 05_run_robot.sh cam                        # 自动问机器人要相机地址（第一帧要等 8~10 秒）
bash 05_run_robot.sh rviz                       # 自动加载项目配置（话题已填好）
bash 05_run_robot.sh rviz ~/my_view.rviz       # 指定自己的配置
bash 05_run_robot.sh qtgui
```

**`core` 模式做了什么**（本套件推荐）：

1. 后台启动 `micro_ros_agent`：监听 UDP `:8888`，双向桥接下位机
   （日志写 **`/tmp/leap_ros_agent.log`**、默认 `-v4`；以前 `-v6` 打终端 30 秒 32MB 会刷死终端）
2. 前台启动 `xuegecar_bringup`：加载 URDF 模型、发布 `odom → base_footprint` TF
3. **启动 12 秒内自检 Agent 会话**：连上就打印 `[ OK ] 机器人已连接`；
   没连上直接给出「按 RESET 或跑 `05_run_robot.sh reset`」的指引
4. 退出时自动清理后台 Agent（`trap`），不会残留占用 8888

**`reset` 模式做了什么**（固件有个"连过就不再重连"的行为，这是它的对症工具）：

1. 自动扫描本网段找到机器人（也可 `bash 05_run_robot.sh reset <机器人IP>`）
2. 读 `/api/status`，与本机 IP 比对：Agent IP 不对就顺手改对
3. `POST /api/runtime-config` → 机器人重启（等价按 RESET 键），实测约 23 秒完成
4. 再查一次，确认 `/scan` 是否回来

**`bringup` 模式做了什么**（`xuegeros_demo/bringup_all.launch.py`）：

1. **立即**启动 `socat`：把 UDP `:8889` 转发为虚拟串口 `/dev/lidar`（**需 root**）
2. **立即**启动 `micro_ros_agent`：监听 UDP `:8888`
3. **延迟 5 秒**启动 YDLIDAR 驱动（等待 `/dev/lidar` 生成）
4. **延迟 7 秒**启动底盘 bringup

> ⚠️ `bringup` 里的 socat 需要 root，官方 launch 文件**硬编码了一个 sudo 密码**，
> 在密码不同的机器上必然失败。该文件是为**外接独立 YDLidar** 准备的；
> 本套件的雷达接在主控板上，数据走 micro-ROS 的 `/scan` 话题，**用 `core` 模式即可**。

---

## 五、关键配置说明

### 5.1 通信链路

| 链路 | 协议 | 端口/设备 | 说明 |
|------|------|-----------|------|
| 上位机 ↔ 主控 | micro-ROS over UDP | `:8888` | **主链路**：`/odom` `/imu` `/scan` `/battery_state` 上行，`/cmd_vel` 下行 |
| 上位机 ↔ 图传 | HTTP / MJPEG | `:81` | 视频流（同一 WiFi 局域网） |
| 图传 配网页 | HTTP | `192.168.1.88:80` | **图传板** AP 模式下的配网门户（热点名 `Maturo_CAM_*`） |
| 主控 配网页 | HTTP | `192.168.4.1:80` | **主控板** AP 模式下的配网门户（热点名 `Maturo_*`） |
| 上位机 ← 外接 YDLidar | socat UDP→PTY | `:8889` → `/dev/lidar` | **仅外接独立 YD 雷达时需要** |

**主控经 micro-ROS 发布/订阅的话题**（源码：`leap_low_v1/main/tasks/network/microros_task.cpp`）：

| 方向 | 话题 | 类型 | 频率 |
|------|------|------|------|
| 机器人 → 上位机 | `/odom` | `nav_msgs/Odometry` | 50 Hz |
| 机器人 → 上位机 | `/imu` | `sensor_msgs/Imu` | 50 Hz |
| 机器人 → 上位机 | `/scan` | `sensor_msgs/LaserScan` | 360 点 |
| 机器人 → 上位机 | `/battery_state` | `sensor_msgs/BatteryState` | 50 Hz |
| 上位机 → 机器人 | `/cmd_vel` | `geometry_msgs/Twist` | — |

### 5.2 雷达配置

**本套件的雷达接在主控板上**（源码：`leap_low_v1/main/tasks/sensors/lidar_task.cpp`）：

```
Camsense 激光雷达 ──UART1 (GPIO41, 115200)──→ 主控解析 360 点 ──micro-ROS──→ /scan
```

因此上位机**不需要** socat、不需要 `/dev/lidar`、不需要 YDLIDAR 驱动。

`ydlidar_ros2_driver/params/*.yaml` 里那些 `/dev/ttyUSB0` 配置，
是给**直接插在电脑 USB 上的 YDLidar** 用的，与本套件无关：

```yaml
port: /dev/lidar          # 由 socat 创建的虚拟串口（外接 YD 雷达方案）
baudrate: 115200
```

> 想确认雷达是否正常，直接看话题：
> ```bash
> ros2 topic hz /scan          # 应有稳定频率
> ```

### 5.3 底盘参数

下位机固件中 `kTrackWidth = 131.7 mm`（轮距），源码位置：
`leap_low_v1/main/control/motion_controller.cpp`

### 5.4 配网（主控 + 图传）

**两套配网机制，别搞混 —— 两块板子各有各的热点和配网页地址：**

| 板子 | 热点名 | 配网页 | 作用 |
|------|--------|--------|------|
| **主控** `leap_low_v1` | `Maturo_<MAC后12位>` | `http://192.168.4.1` | 电机/IMU/雷达/micro-ROS |
| **图传** `leap_cam` | `Maturo_CAM_<MAC后12位>` | `http://192.168.1.88` | WiFi 图传摄像头 |

> ⚠️ **名字里带 `CAM` 的是图传板，不带的是主控板。**
> 连错热点再去访问另一个板的地址，会得到 **"服务器响应时间过长"** ——
> 那个地址不在当前网段，数据包被默认路由发到外网去了，必然超时。
> 不确定自己连的是哪块板，跑 `bash 10_diag_portal.sh` 自动判别。

**① 主控配网（最重要）** —— 决定机器人能不能和上位机通信

| 项目 | 值 |
|------|-----|
| 热点名 | `Maturo_<MAC后12位>`，例如 `Maturo_A1B2C3D4E5F6` |
| 热点密码 | **无**（开放网络） |
| 配网页 | `http://192.168.4.1` |
| 默认 WiFi | `Maturo` / `maturo2026`（作者的，建议改） |
| 可配置项 | WiFi 名称密码、**micro-ROS Agent IP**、端口、通信模式 |

触发逻辑（源码 `app_runtime.cpp`）：上电后先尝试连已保存的 WiFi，
**15 秒超时失败即启动配网热点**，此时主控 LED **快闪**。
连上 WiFi 后 LED 转为慢闪/常亮。

> ⚠️ **`micro-ROS Agent IP` 必须填上位机的 IP**（不是路由器 IP、不是机器人 IP）。
> 出厂默认是作者的 `192.168.31.214`，不改就永远连不上。
> 用 `bash 09_preflight.sh` 可以一键查出本机 IP。

**② 图传配网** —— 图传板自己也有配网页面

图传板首次上电会进 AP 模式（热点名 `Maturo_CAM_<MAC后12位>`），
连接后打开 **`http://192.168.1.88/`**（定义见源码 `leap_cam/main/wifi_manager.h:8`），
表单字段为 `-wf_ssid` / `-wf_key`。

> 💡 图传板 AP 网段是 **`192.168.1.0/24`**，和很多家用路由器的默认网段撞车。
> 如果家里路由器本身就是 `192.168.1.x`，图传板连上去后容易 IP 冲突，
> 建议把路由器网段改成 `192.168.31.x` 之类。

**更省事的做法**：主控配网页上有"摄像头配网"功能，可以**直接给图传板下发 WiFi 配置命令**，
不用单独去连图传板的热点。

> 📡 **ESP32 只支持 2.4GHz WiFi。** 若路由器开了"双频合一"，建议为 2.4G 单独设一个 SSID。

### 5.5 micro-ROS Agent 启动命令

```bash
ros2 run micro_ros_agent micro_ros_agent udp4 --port 8888 -v6
```

> `-v6` 是最高日志级别，调试时可保留；正式使用可改为 `-v4`。

---

## 六、常见问题排查

### Q1：`sudo` 提示 "no new privileges flag is set"

这是容器/沙箱环境的限制。请在**宿主机终端**中直接执行安装脚本，不要通过受限沙箱运行。

### Q2：串口打不开（Permission denied / could not open port）

**先查真实状态，再动手：**

```bash
ls -l /dev/ttyUSB* /dev/ttyACM*
udevadm info -q property -n /dev/ttyUSB0 | grep -E 'VENDOR_ID|MODEL_ID'
groups | grep dialout
```

按结果分两种原因：

**原因 A —— udev 规则没匹配到该芯片**（最常见，也最反直觉）

规则里若把 CH340 写死成 `ATTRS{idProduct}=="7523"`，而实际芯片上报的是 `1a86:7522`，
规则**不会匹配** → 设备权限停在默认的 `root:dialout 660`，而不是规则里写的 `0666`。
此时你**即使已经在 dialout 组里也打不开**（当前终端会话没带上该组）。

```bash
sudo bash 11_fix_serial_perm.sh     # 一键修复：重写规则 + reload + 重新触发 + 验证
```

该脚本把 `1a86` 改为按 **vendor 通配**（覆盖 7522/7523 等所有 CH34x），
并加 `TAG+="uaccess"`，让当前登录用户免重登即可访问。

**原因 B —— 组已生效但当前终端是旧的**

```bash
sudo usermod -aG dialout $USER
newgrp dialout          # 仅本终端生效
# 或注销后重新登录       # 永久生效
```

**兜底**：规则改完仍不生效时，**拔掉 USB 线再插回**（已插入的设备不会因 reload-rules 自动重新应用权限）。

### Q3：ROS 2 与 ESP-IDF 冲突 / 烧录脚本"跑一半静默退出"

**症状**：`bash 04_flash_firmware.sh low` 只打印 `==> 1/5 加载 ESP-IDF 环境`，
然后**没有任何报错就回到提示符**（退出码 1）。

**原因链**（隐蔽，因为报错被 `>/dev/null 2>&1` 吞掉了）：

1. `~/.bashrc` 里 `source /opt/ros/humble/setup.bash` —— **每个新终端都会自动加载 ROS 2**；
2. ROS 2 改变 `PATH`/`PYTHONPATH`，使 `python3` 指向 `/usr/bin/python3`（3.10）；
3. ESP-IDF 的 `export.sh` 据此推导 python 虚拟环境为 `idf5.5_py3.10_env`；
4. 但工具链安装时用的是 3.13 → 实际只有 `idf5.5_py3.13_env`；
5. `export.sh` 末尾 `. <venv>/bin/activate` 失败 → 在 `set -e` 下**终止调用方脚本**；
6. 输出被重定向到 `/dev/null` → 你什么也看不到。

**ESP-IDF 与 ROS 2 都改 `PYTHONPATH`，天生不能在同一 shell 共存。**

**已修**：`04_flash_firmware.sh` 现在会
① `unset PYTHONPATH / ROS_* / AMENT_* / COLCON_PREFIX_PATH / CMAKE_PREFIX_PATH`；
② 显式 `export IDF_PYTHON_ENV_PATH=<实际安装的 idf*_env>`（依据 `tools/idf_tools.py:get_python_env_path()`）；
③ 先在子 shell 预跑 `export.sh`，失败时打印完整原始输出（不再静默）；
④ 加 ERR 陷阱，任何被 `set -e` 终止的情况都会打出行号与命令。

**手动激活 ESP-IDF 时**（交互式用 `idf.py`）：不要用旧版 `alias get_idf`，
它无法清理环境。重跑 `bash 03_install_espidf.sh`（幂等）会写入一个带清理的
`get_idf` **函数**；或手动执行：

```bash
unset PYTHONPATH AMENT_PREFIX_PATH ROS_DISTRO ROS_VERSION CMAKE_PREFIX_PATH
export IDF_PYTHON_ENV_PATH=$(ls -d ~/.espressif/python_env/idf*_env | tail -1)
source ~/esp/esp-idf/export.sh
```

> 更根本的做法：把 `~/.bashrc` 里的 `source /opt/ros/humble/setup.bash` 去掉，
> 改成需要时手动 `source`。ROS 2 的自动加载正是这个坑的源头。

### Q4：`colcon build` 报缺依赖

```bash
# 用 rosdep 自动补装（先确保 rosdep 已初始化）
rosdep install --from-paths ~/leap_ros_ws/src --ignore-src -r -y
```

### Q5：雷达 `/dev/lidar` 不存在

`socat` 需要在 launch 启动时运行，且 `bringup_all.launch.py` 中硬编码了 sudo 密码 `xuegeros`。
如果系统密码不同，需修改：

```python
# ~/leap_ros_ws/src/xuegeros_demo/launch/bringup_all.launch.py
sudo_password = "你的密码"
```

或者手动创建虚拟串口：

```bash
sudo socat -d -d PTY,link=/dev/lidar,raw,echo=0,mode=666 UDP4-LISTEN:8889,reuseaddr,fork
```

### Q6：micro-ROS Agent 连不上底盘

1. 确认底盘已上电，且与电脑在**同一局域网**
2. 检查下位机固件通信模式是否为 micro-ROS（v1.5 支持 micro-ROS / MAVLink 切换）
3. 放通 UDP `8888` 端口（防火墙）
4. 用 `-v6` 查看 Agent 详细日志

### Q7：GitHub 下载超时

本环境 GitHub 直连受限。解决方案：
- ROS GPG key：脚本已内置 Gitee 回退
- ESP-IDF 工具链：已配置 `dl.espressif.cn` 镜像
- micro-ROS-Agent（已随本指南部署完成，无需重新下载）

### Q8：编译固件报 `Missing esp-mqtt submodule`

**这是本指南踩过的坑，务必注意。**

ESP-IDF 依赖 23 个 git 子模块（esp-mqtt、mbedtls、lwip、esp-wifi-lib 等）。
从 **Gitee 归档包**（`repository/archive/*.tar.gz`）获取的源码**不含子模块**，
任何工程编译都会失败。

`03_install_espidf.sh` 已修正为使用 `git clone --recurse-submodules`。
若你已用归档包安装，可这样修复：

```bash
cd ~/esp/esp-idf
git submodule update --init --recursive --depth 1
```

或彻底重装（推荐）：

```bash
rm -rf ~/esp/esp-idf
git clone --depth 1 --single-branch -b v5.5.3 \
  --recurse-submodules --shallow-submodules \
  https://github.com/espressif/esp-idf.git ~/esp/esp-idf
```

验证子模块是否完整：

```bash
ls ~/esp/esp-idf/components/mqtt/esp-mqtt | head    # 应列出文件，不能为空
```

### Q9：`idf.py --version` 报 "不是 Git 仓库"

归档包缺少 `.git` 元数据。**该警告输出到 stderr，不影响编译烧录**，
`idf.py --version` 实际仍正确返回版本号。使用 git clone 安装可避免此警告。

### Q10：ESP-IDF 安装卡在 pip 下载

国内直连 PyPI 很慢。已配置清华镜像 `~/.config/pip/pip.conf`。
若仍卡住，手动指定：

```bash
export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
cd ~/esp/esp-idf && ./install.sh esp32s3
```

### Q11：编译主控固件报 `PermissionError: ... /root/maturo_project/...`

**这是本指南踩过的第二个坑。**

`leap_low_v1/dependencies.lock` 缓存了原作者的**本机绝对路径**：

```
path: /root/maturo_project/leap_low_v1/managed_components/micro_ros_espidf_component
```

在其他机器上该路径不存在，组件管理器解析失败。

**修复**（编辑 `dependencies.lock`，改为相对路径）：

```bash
cd ~/leap_firmware/leap_low_v1
# 备份后修正
cp dependencies.lock dependencies.lock.orig
sed -i 's#^\( *path: \).*\(managed_components/.*\)$#\1../\2#' dependencies.lock
grep path: dependencies.lock     # 应显示 ../managed_components/...
```

`04_flash_firmware.sh` 已内置该自动修正逻辑。

> 注意：`main/idf_component.yml` 中本来就是正确的相对路径
> `../managed_components/micro_ros_espidf_component`，
> 只有 `dependencies.lock` 被缓存成了绝对路径。

> **补充说明**：IDF 组件管理器每次构建都会把 lock 中的 `path` 重写为
> **本机当前绝对路径**（例如 `/home/你的用户名/leap_firmware/leap_low_v1/...`）。
> 这**属于正常行为，无需处理** —— 只要该路径在本机真实存在即可。
> 只有路径指向**别的机器**（如 `/root/maturo_project/...`）时才是问题。
> `99_check_env.sh` 按此逻辑判断：验证路径是否真实存在，而非简单匹配 `/root`。

### Q14：`Could not find a package configuration file provided by "ydlidar_sdk"`

**这是本指南踩过的第五个坑，也是本环境真正缺的一项依赖。**

`ydlidar_ros2_driver/CMakeLists.txt` 第 25 行：

```cmake
find_package(ydlidar_sdk REQUIRED)
```

YDLidar-SDK **不在 ROS apt 源里**，必须单独从源码编译安装：

```bash
cd /media/lixin/新加卷/robot/setup
bash 08_install_ydlidar_sdk.sh            # 装到 ~/.local（无需 sudo，推荐）
bash 08_install_ydlidar_sdk.sh --system   # 装到 /usr/local（需 sudo，官方做法）
```

装到 `~/.local` 时，`02_build_workspace.sh` 会自动探测该前缀并传入
`CMAKE_PREFIX_PATH`，无需手动配置。

> 官方 YDLidar-SDK 仓库**没有 `humble` 分支**，用 `master` 即可（同时兼容 Humble）。
> 因其为纯 CMake 库（无 `package.xml`），不能直接丢进 `src/` 参与 colcon 构建。

**装完后如果链接报 `找不到 -lydlidar_sdk`：**

YDLidar-SDK 自动生成的 `ydlidar_sdkConfig.cmake` 里，`YDLIDAR_SDK_LIBRARY_DIRS`
这一项是**空的**（SDK 自身的打包缺陷，实测确认）：

```cmake
SET( YDLIDAR_SDK_LIBRARY_DIRS  CACHE INTERNAL "YDLIDAR_SDK library directories" FORCE )
```

而驱动只用 `link_directories(${YDLIDAR_SDK_LIBRARY_DIRS})` 定位库，于是链接阶段
找不到 `libydlidar_sdk.a` 所在目录。

- 装到 `/usr/local`：**不受影响** —— `/usr/local/lib` 本就是链接器的默认搜索路径；
- 装到 `~/.local` 等非系统前缀：`02_build_workspace.sh` 已自动补充
  `LIBRARY_PATH=<prefix>/lib` 兜住。

所以**能 sudo 时优先用 `--system`**（也更贴近官方文档）；无 sudo 时用默认用户前缀亦可，
脚本已处理。

### Q15：构建报 `ModuleNotFoundError: No module named 'catkin_pkg'`

ament 的 `package_xml_2_cmake.py` 依赖 `catkin_pkg`，而 `catkin_pkg` 只装在
ROS 2 Humble 绑定的**系统 Python**（`/usr/bin/python3`，3.10）里。

若 `PATH` 中 `python3` 被 conda / 独立 Python 抢占，CMake 会调用那个解释器从而报错。
错误信息里会打印**实际使用的解释器全路径**，据此判断：

```
execute_process(/home/xxx/miniconda3/bin/python3
  /opt/ros/humble/share/ament_cmake_core/cmake/core/package_xml_2_cmake.py ...)
ModuleNotFoundError: No module named 'catkin_pkg'
```

`02_build_workspace.sh` 已内置检测：发现当前 `python3` 缺少 `catkin_pkg` 时，
自动切回 `/usr/bin/python3` **并显式传给 CMake**。

手动构建时的等价写法：

```bash
colcon build --cmake-args \
  -DPython3_EXECUTABLE=/usr/bin/python3 -DPYTHON_EXECUTABLE=/usr/bin/python3
```

> **两个容易忽略的点**：
> 1. 只改 `PATH` 往往不够 —— CMake 会把解释器路径缓存进 `CMakeCache.txt`，
>    后续配置继续复用该旧值。所以必须靠显式 `-D`（覆盖缓存）或 `--clean` 全量重编。
> 2. 确认系统真有该包：`dpkg -l python3-catkin-pkg-modules`；
>    若缺失则 `sudo apt install -y python3-catkin-pkg-modules python3-empy`。

### Q16：`ros2 topic list` 看不到 `/scan` `/odom`，机器人「连不上」

**先跑这个，它会自动扫出机器人并直接告诉你哪里不对：**

```bash
bash 09_preflight.sh        # 不用带参数，会自动扫描本网段
```

它会自动扫出机器人 IP（读 `/api/status` 里 `device_name` 是否以 `Maturo_` 开头），
并核对 **Agent IP 是否等于你电脑的 IP**、**通信模式是否为 `micro_ros`**，
同时打印 WiFi 信号、雷达点数、电量、温度。

**再跑这个，它会直接报「Agent 会话建立没有」+ 关键话题在不在**（比 `ros2 topic list` 直观）：

```bash
bash 05_run_robot.sh topics
```

然后按顺序排查（按出现频率排序）：

1. **Agent IP 不是你这台电脑的 IP** ← 最高频
   症状：`/api/status` 里 `microros_agent_ip` 显示 `192.168.31.214`（原作者的值）或一个旧 IP。
   修法见 **Q21** —— 一条 `curl` 搞定，**不需要连机器人热点**；
   或直接 `bash 05_run_robot.sh reset`（自动扫机器人 + 自动填本机 IP + 复位）。

2. **通信模式不是 `micro_ros`**（而是 `mavlink_udp`）
   此时 `/odom`、`/imu`、`/scan`、`/cmd_vel` 全都不会出现。

3. **启动顺序反了：机器人比 Agent 早连过 / Agent 重启过** ← 第二高频
   固件里 `spin_once()` 把 `rcl_wait` 的超时当作"正常"返回，
   所以**连接一旦建立过，机器人就再也不会去 ping Agent**。
   → **必须先起 Agent，再复位机器人**。一键复位：
   ```bash
   bash 05_run_robot.sh reset      # 等价于按主控板 RESET 键，实测约 23 秒完成
   ```

4. **Agent 没在运行**：`bash 05_run_robot.sh core`。
   若提示 `UDP :8888 已被占用`，说明已有 Agent 在跑 —— 这通常是好事（直接去用就行）；
   但如果那个 Agent 是**上次终端被直接关掉留下的孤儿进程**，就按 **Q23** 处理。

5. **电脑与机器人不在同一网段**：`bash 09_preflight.sh` 会同时打印两者的 IP 供对比。

> 📌 **判断时别只看 `/odom`**：`xuegecar_bringup` 只**订阅** `odom`（把 odom 转成 TF），
> 并不发布。所以机器人根本没连上时，`/odom` 这个名字照样会出现在 `ros2 topic list` 里，
> 但**永远没有数据**。可靠判据是 `/scan` `/imu` `/battery_state` **三个同时存在且有数据**。

> ⚠️ 若路由器/热点开了 **AP 隔离（客户端隔离）**，无线设备之间无法互访。
> 手机热点一般没有隔离；**校园网几乎一定有**，而且还需要 Portal 认证
> （ESP32 过不去），所以**不要用校园网** —— 用手机热点或家用路由器。

### Q17：搜不到 `Maturo_` 配网热点

- 固件没烧或没烧成功 → 重跑 `bash 04_flash_firmware.sh low`
- 板子没上电 / 电池电压不足
- **已经连上 WiFi 了** —— 此时不会开热点（不是故障）

### Q18：机器人配上网了，但过几天又连不上

路由器/手机热点 DHCP 重新分配后，**你电脑的 IP 可能变了**，而主控里存的还是旧 IP。

**不用连热点、不用开浏览器**，两条命令改掉：

```bash
bash 09_preflight.sh                                   # 查本机 IP，并自动找到机器人 IP
curl -X POST http://<机器人IP>/api/runtime-config \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'comm_mode=micro_ros&microros_agent_ip=<本机IP>&microros_agent_port=8888'
# 返回 {"ok":true,"restart":true} → 机器人自动重启，约 10 秒后重连
```

> 为什么能这样改：主控板**连上 WiFi 后配网页仍然开着**（STA 模式 TCP 80 仍在监听），
> 所以只要机器人已经在局域网里，HTTP 就能直接读写它的配置，**不必去连它的 AP 热点**。

**根治办法**：在路由器里给你的电脑设置 **DHCP 静态绑定**（MAC 地址保留），
让它每次都拿到同一个 IP。

> 手机热点一般做不了静态绑定，所以**每次换热点/换网络都要回来改一次 Agent IP**。

### Q19：访问 `192.168.4.1` 提示"服务器响应时间过长"/无法访问

**99% 是连错热点了。** 机器人有两块板子，各自发热点、各有配网页：

| 热点名 | 板子 | 正确配网页 |
|--------|------|-----------|
| `Maturo_CAM_<MAC>` | 图传板 | `http://192.168.1.88` |
| `Maturo_<MAC>` | 主控板 | `http://192.168.4.1` |

连了图传板却访问 `192.168.4.1`，该地址不在当前网段 → 数据包被默认路由
（有线网口/校园网）发到外网 → 超时。

**一键判别：**

```bash
bash 10_diag_portal.sh
```

它会打印当前 WiFi 的网关、探测出配网页标题、并告诉你该开哪个地址。

**手动验证（看数据包到底走了哪条路）：**

```bash
ip route get 192.168.4.1
# 输出带 "dev <你的WiFi网卡>" → 正确，在本网段
# 输出带 "dev <有线网卡> via <网关>" → 错的，包被发到外网了
```

### Q20：主控板上的灯分别是什么意思？（红灯 / 白灯）

**主控板上有两个独立的灯，一个是硬件电源灯，一个是固件状态灯。**

| 灯 | 电路 | 控制方 | 含义 |
|---|---|---|---|
| **电源指示灯**（板右侧，`3V3 → R23 5.1kΩ → LED → GND`） | 硬件直连 | **固件管不了** | **常亮 = 供电正常**。它永远不闪 |
| **状态灯 LED1**（白色 0603 `KT-0603W`，`GPIO14 → R1 5.1kΩ → LED1`） | 固件驱动 | `status_led` | 见下表 |

状态灯语义（源码 `components/status_led/status_led.cpp`，上电有效电平为高）：

| 现象 | 翻转周期 | 代码 | 含义 |
|---|---|---|---|
| 灭 | — | `kOff` | 没上电 / 未跑到初始化 |
| **常亮** | — | `kOn` | **已连上 WiFi** |
| **快闪**（急促，每秒约 4 次） | 120 ms | `kFastBlink` | **没连上 WiFi → 已开配网热点 `Maturo_xxxx`** |
| **慢闪**（一秒 1 次） | 500 ms | `kSlowBlink` | 按过 BOOT 键，模式切到 **micro-ROS** |

> **判据：白灯在闪 = 没连上 WiFi；白灯常亮 = 连上了。**

状态机的全部置灯点（`grep -rn 'status_led\.' main/` 只有 3 处）：

| 位置 | 动作 |
|---|---|
| `app_runtime.cpp:144` 上电初始化后 | → `kOn`（常亮） |
| `app_runtime.cpp:61` `wifi_init_sta()` 失败分支 | 开 softAP + → `kFastBlink` |
| `peripheral_task.cpp:30` `toggle_wifi_comm_mode()` | micro-ROS → `kSlowBlink`；MAVLink → `kOn` |

时序：

```
上电 → 白灯常亮
     → 连已保存的 WiFi（无凭据时试默认 Maturo / maturo2026）
     → 等 15s（kWifiConnectTimeoutMs = 15000）
        ├─ 成功 → 白灯保持常亮，启动通信任务
        └─ 超时 → 开热点 Maturo_<MAC后12位> + 白灯快闪
```

**两个容易误判的点：**

1. **灯不能用来判断通信模式。** STA 一连上白灯就常亮，不论 micro-ROS 还是 MAVLink ——
   只有"按 BOOT 键切换的那一刻"才会用慢闪/常亮区分。要确认模式请看配网页或串口日志。
2. **软 AP 与快闪是同一个分支**：能搜到 `Maturo_xxxx` 热点，就说明灯一定是快闪、且 WiFi 没连上。

**BOOT 键（GPIO0）**：短按（按住 50~1200ms 松开）= 切换通信模式。
但 GPIO0 是 strapping 脚，**上电瞬间按住会进下载模式**，别在复位时按。

---

### Q21：不连热点，直接用 HTTP 读状态 / 改配置

主控板**连上 WiFi 后配网页仍在监听**（STA 模式 TCP 80），所以不需要连它的 AP 热点，
只要机器人已经在局域网里，HTTP 就能直接读写配置：

```bash
ROBOT=10.182.70.244            # 用 bash 09_preflight.sh 自动查出来

# ① 读完整状态（排查神器）
curl -s http://$ROBOT/api/status | python3 -m json.tool

# ② 改通信模式 / Agent IP / 端口
curl -X POST http://$ROBOT/api/runtime-config \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'comm_mode=micro_ros&microros_agent_ip=10.182.70.36&microros_agent_port=8888'
# → {"ok":true,"restart":true}，机器人自动重启，约 10 秒后重连
```

> 💡 **懒人版**（①②合一，还会自动扫出机器人、自动填本机 IP、复位后自动检查会话）：
> ```bash
> bash 05_run_robot.sh reset
> ```

**固件提供的全部端点**（源码 `tasks/network/wifi_provision_task.cpp` 注册表）：

| 端点 | 方法 | 作用 |
|---|---|---|
| `/` | GET | 配网页 HTML |
| `/api/status` | GET | 完整状态 JSON |
| `/api/scan` | GET | 扫描周围 WiFi |
| `/api/provision` | POST | 配网（`ssid` / `password`）|
| `/api/runtime-config` | POST | `comm_mode` / `microros_agent_ip` / `microros_agent_port` |
| `/api/camera/provision` | POST | 给图传板下发 WiFi 配置 |

`/api/status` 里最该看的字段：

| 字段 | 含义 |
|---|---|
| `wifi.sta_connected` | `true` = 已连上 WiFi |
| `wifi.rssi` | 信号强度（-30 优秀 ／ -70 偏弱）|
| `runtime.microros_agent_ip` | **必须等于你电脑的 IP** |
| `runtime.comm_mode` | 必须是 `micro_ros` |
| `lidar.valid_points` | > 0 说明雷达在工作 |
| `battery.percentage` / `temperature.celsius` | 电量 / 温度 |

**这条路能绕开的坑**：主控板热点信号弱、被同频干扰、网卡关联被踢（
表现为 `nmcli` 报 `802.1X 请求方验证时间过长`）时，"连热点配网"根本走不通，
但只要机器人已经连上路由器，HTTP 这条路完全不受影响。

#### ⚠️ 启动顺序：必须先起 Agent，再复位机器人

固件 `microros_task.cpp` 的 `spin_once()`：

```c
ret = rcl_wait(&s_wait_set, RCL_MS_TO_NS(timeout_ms));
if (ret == RCL_RET_TIMEOUT) {
    return true;        // ← 超时也返回 true，于是永远不触发重建
}
```

连接一旦建立，`s_ros_created` 恒为真，机器人**再也不会重新 ping Agent**：

| 场景 | 结果 |
|---|---|
| 机器人刚上电/复位时，Agent 已在跑 | **2 秒内**握手成功 ✅ |
| 机器人已跑很久，Agent 才起来 | 30 秒毫无反应 ❌，**必须复位机器人** |
| 机器人从未连上过（首次配网后）| 每 1.9 秒重试（`rmw_uros_ping_agent(300,3)` + 1s 延时），会自动连上 ✅ |

> 标准操作：**先跑 `bash 05_run_robot.sh core`，再复位机器人** ——
> 按主控板 RESET 键，或在另一个终端执行 `bash 05_run_robot.sh reset`（推荐，会顺带核对 Agent IP）。
> `core` 模式会自己检查会话，没连上时直接把这段指引打在屏幕上。

---

### Q22：Agent 到底连上没有？日志在哪？为什么终端被刷屏？

**① 一条命令看结论：**

```bash
bash 05_run_robot.sh topics
```

输出三段：**Agent 会话状态**（有没有 `session established`）、**当前话题列表**、
**机器人 4 个关键话题在不在**（`/scan` `/odom` `/imu` `/battery_state`）。

**② Agent 日志现在落盘，不再刷终端：**

```bash
tail -f /tmp/leap_ros_agent.log        # 实时看
grep 'session established' /tmp/leap_ros_agent.log   # 只看握手那一行
```

> 以前 `core` / `agent` 用 `-v6` 把 Agent 日志**直接打到终端**，实测 **30 秒产出 32MB**，
> 终端会被刷到卡死、滚不动。现在默认 `-v4` 且写文件。
> 真需要 hex dump 排障时：`AGENT_VERBOSE=6 bash 05_run_robot.sh agent`（日志仍写文件）。

**③ 会话有没有建立，看这两行：**

```
session established  | address: 10.182.70.244:47138     ← ✅ 机器人连上了
participant created  | participant_id: 0x000(1)         ← ✅ 实体创建成功
```

**④ 手动查端口/进程（不看日志也能判断）：**

```bash
ss -lunp | grep 8888         # 有 UNCONN 0.0.0.0:8888 且带 pid= → Agent 在监听
pgrep -af micro_ros_agent    # 看 Agent 进程在不在
ps -o pid=,ppid=,etime=,cmd= -p <上面拿到的pid>   # ppid=1/systemd 说明是孤儿（见 Q23）
```

**⑤ 连诊断逻辑本身都可以独立验证**：换一个端口起自己的 Agent，
如果它能立刻握手成功，说明**机器人侧完全正常**，问题一定在上位机这一侧：

```bash
# 把机器人临时指向 8899 做隔离验证（会重启机器人，验完记得改回 8888）
curl -X POST http://<机器人IP>/api/runtime-config \
  --data 'comm_mode=micro_ros&microros_agent_ip=<你的IP>&microros_agent_port=8899'
ros2 run micro_ros_agent micro_ros_agent udp4 --port 8899 -v4
```

### Q23：提示 `UDP :8888 已被占用`，但那个终端早就关了（孤儿进程）

**现象**：把终端窗口直接**叉掉**（或关机重登、SSH 断线）后，脚本再跑 `core` 就报：

```
[ERR ] UDP :8888 已被占用 —— 可能已有 micro-ROS Agent 在运行
[ERR ] 到启动它的那个终端按 Ctrl+C 关掉，再重跑本命令
```

而那个终端**已经不在了，Ctrl+C 根本没地方按**。

**原因**：终端关闭时，里面的 Agent 并不会一起退出，它被**重新挂到 `systemd --user` 下面**，
成了「孤儿进程」，继续占着 8888 —— 实测最久残留过 **24 分钟**。

**身份判据**：父进程变成 `1`(init) 或 `systemd`。

```bash
ss -lunp | grep 8888              # 拿到 pid=xxxxx
ps -o pid=,ppid=,tty=,cmd= -p <pid>   # ppid=1 或 ppid 是 systemd → 孤儿
```

> ⚠️ **别用 `tty` 字段判断**：实测孤儿进程的 `tty` 仍显示 `pts/N`，会误判成"还在某个终端里"。

**处理（三选一）**：

```bash
# ① 直接杀掉（最省事）
kill <pid>                    # 不生效再 kill -9 <pid>

# ② 让脚本代劳：自动结束占用者再启动
bash 05_run_robot.sh core --force

# ③ 先只看看是谁占着
bash 05_run_robot.sh topics   # 会打印 PID、运行时长、是否孤儿
```

**杀完之后还要做一步**：旧 Agent 一退出，机器人那边的会话就断了，
而固件**不会自动重连**（见 Q16 第 3 条），所以必须复位机器人：

```bash
bash 05_run_robot.sh reset    # 在另一个终端执行，约 23 秒
```

**根治习惯**：别用窗口右上角的 ✕ 关终端，**要在终端里按 `Ctrl+C`** ——
`core` 模式注册了退出清理（`trap cleanup EXIT INT TERM`），按 Ctrl+C 会顺手把 Agent 收掉。

### Q24：RViz 怎么用？LaserScan 一片红字 `Status: Error`

**先看结论**：红字几乎都是因为 **`Topic` 是空的**。
裸跑 `rviz2` 是**空白配置**，Displays 里每个显示项的话题都要自己填。

```bash
# 推荐：直接加载项目自带配置，话题已填好（/scan /odom /map）
bash 05_run_robot.sh rviz
# 也可以指定自己的配置
bash 05_run_robot.sh rviz ~/my_view.rviz
```

**修红字**：左侧选中 `LaserScan` → 下方点 `Topic` 下拉框 → 选 **`/scan`**。
（`/scan` 由下位机 `leap_low_driver` 发布，实测 ~5Hz，`RELIABLE` —— 和 RViz 默认 QoS 一致，不用改。）

**鼠标操作（中间 3D 黑区）**：

| 操作 | 效果 |
|---|---|
| 左键拖 | 旋转视角 |
| 中键拖（按滚轮） | 平移视角 |
| 滚轮 | 缩放 |
| 左键单击 | 选中物体 |

**顶部工具条**（建图/导航阶段才有用）：

| 按钮 | 用途 |
|---|---|
| `2D Pose Estimate` | 导航时告诉车"你实际在哪、朝哪"（按住拖出箭头） |
| `2D Goal Pose` | 导航时点一个目标点，车自己开过去 |
| `Publish Point` | 发一个 `/clicked_point`，调试用 |

**左侧 Displays 面板**：
- 每项前面的复选框只是**隐藏/显示**，不是删除
- 点中某一项，**下方就是它的参数**（Topic / Style / Size）
- **点太小看不清** → 把 `Size (m)` 从 `0.01` 改成 `0.02~0.03`
- 底部 `Add` 加显示（`Map` / `RobotModel` / `TF` 等），`Remove` 删除

**右侧 Views 面板**：底部 `Save` 把当前配置存成 `.rviz`，下次不用重填。

> ⚠️ **`Fixed Frame` 要跟着阶段改**：跑 SLAM / Nav2 时用 `map`（项目配置就是 `map`）；
> **只跑核心链路、没起 SLAM 时 `map` 坐标系不存在**，3D 区会全空 —— 此时改成
> `odom` 或 `base_footprint`。

> 📌 项目自带的 `xuegecar_cartographer.rviz` 里还带了 Nav2 的 costmap / 路径显示，
> **没跑 Nav2 时它们会显示成"话题不存在"**，属于正常现象，不想要就在 Displays 里 `Remove`。

---

### Q25：RViz 里地图 / 扫描在「抖动」，车子明明没动

**一句话**：`Fixed Frame = map` 时，机器人显示位姿 = **`map→odom`（陈旧的修正） × `odom→base_footprint`（实时的噪声）**。
gmapping 只在机器人**移动 1 m / 转 0.5 rad / 每 1 秒**时才重算一次 `map→odom`，
所以这中间**里程计的所有噪声都被原封不动地画到屏幕上**。360° 的扫描随偏航来回摆 → 看起来就是一片放射状「辐条」。

**先跑这条命令（机器人必须静止不动）**：

```bash
# 【终端 B】
cd /media/lixin/新加卷/robot/setup
bash 12_diag_jitter.sh
```

它会分别量 `odom→base_footprint`、`map→odom` 的静止抖动、直接问固件 `motion.yaw` / `imu.yaw` 的漂移、以及 `/scan` 的零值与最长连续零段，最后**直接告诉你抖动来自哪一层**。

**三层根因（按可能性排序）**：

| 层 | 证据（代码位置） | 说明 |
|---|---|---|
| **① 固件里程计偏航是"纯轮速差积分"** | `main/control/motion_controller.cpp:166`<br>`odom_yaw_ += local_vw * dt;` | 没有任何绝对基准、没有校正。轮速由编码器 `Δcount/dt` 差分得到，**静止时单个抖动脉冲就会造出虚假角速度**，而且**永久累加进去**。固件里明明已经算好了 `imu_yaw_rel_`，却只用于闭环控制，**没喂给里程计**（`GetOdometry()` 返回的就是 `odom_yaw_`）。 |
| **② gmapping 的更新阈值太大** | `slam_gmapping/src/slam_gmapping.cpp` `init()`：<br>`linearUpdate_ = 1.0; angularUpdate_ = 0.5; temporalUpdate_ = 1.0;` | 对小尺寸室内车来说 1 m / 0.5 rad 太粗 —— 慢慢开的时候几乎全靠 `temporalUpdate` 每 1 秒修正一次，中间全在"裸奔"。 |
| **③ `/scan` 本身质量差** | 实测：360 点里 **115 个是 0（32%）**，**最长连续 35 个点（35°）全为 0**；有效点里 73% 在 1 m 内 | 成片丢点说明有整段角度**收不到回波**（视场被挡 / 供电掉压 / UART 丢包），每帧参与匹配的光束集合不一致 → 匹配结果来回跳。 |

**⚠️ 极重要：`params/slam_gmapping.yaml` 是「死配置」，改了没用**

```bash
# 验证：整个包里没有任何一处读参数
grep -rn "declare_parameter\|get_parameter" ~/leap_ros_ws/src/slam_gmapping/src ~/leap_ros_ws/src/slam_gmapping/include
# → 无输出
```

`slam_gmapping.cpp` 的 `init()` 把**所有参数硬编码**了，而且 `initMapper()` 里还有一句会**无条件覆写**：

```cpp
maxRange_  = scan->range_max - 0.01;   // 12.0 - 0.01 = 11.99（不是 YAML 写的 6.0）
maxUrange_ = maxRange_;                // 11.99（不是 YAML 写的 4.0）
```

所以 **改 YAML 里的 `maxRange` / `maxUrange` / `linearUpdate` / `particles` 一律无效**，
必须**改源码再 `colcon build`**。这也是排查这类问题时最容易白花几小时的地方。

**其他已确认的隐患**（不改也能跑，但会持续添乱）：

| 位置 | 问题 | 影响 |
|---|---|---|
| `microros_task.cpp:253` | 无回波写成 `0.0f`（ROS 惯例应为 `inf`/`NaN`） | gmapping 包装层把 `0` 当"无效"替换成 `range_max=12.0`，只因 `maxUrange=11.99` 才勉强被滤掉（差 0.01，非常脆弱） |
| `microros_task.cpp:355` | `scan_time = 0.1`（宣称 10 Hz），实际 **5.1 Hz** | 任何依赖 `scan_time` 的消费者都会算错速度 |
| `lidar_task.cpp:55-87` | 一圈约 400 个原始点按**整度分箱**并**取最小值** | 必然有空格，且每帧被填满的格子随机变化 → 扫描逐帧闪烁 |
| 电源 | 电量 6.9 V（39%）偏低 | 会影响雷达转速稳定性，建议充满电再复测 |

**优先级建议**：
1. **先跑 `12_diag_jitter.sh` 定性**（静止测）；
2. 若 `motion.yaw` 漂而 `imu.yaw` 稳 → **把 IMU 偏航并入 odom**（改固件，收益最大）；
3. 若 `/scan` 零值 >20% → 查雷达视场遮挡 / 供电 / UART 丢包；
4. 最后才动 gmapping 参数（记得改源码，不是 YAML）。

---

### Q26：相机（视频流）怎么配？`curl http://<相机IP>:81/` 一直没响应是不是坏了？

**不是坏了，是相机要预热。**

`leap_cam` 的 MJPEG 服务（`web_mjpeg.c`，端口 **81**，路径就是 `/`）只有在**抓到第一个 JPEG 帧之后**
才会发出 HTTP 状态行和响应头。从 TCP 建连到第一帧出来需要 **8~10 秒**：

```
$ curl -v --max-time 8 http://192.168.1.102:81/
* Connected to 192.168.1.102 port 81
> GET / HTTP/1.1
* Operation timed out after 8001 ms with 0 bytes received     ← 8 秒太短，误判
```

把超时放到 20 秒就正常了：

```
$ curl -s --max-time 20 -o /tmp/cam.bin -w 'HTTP %{http_code} %{content_type} %{size_download}\n' http://192.168.1.102:81/
HTTP 200  multipart/x-mixed-replace;boundary=frame  9295773
```

即 **20 秒收 9.3 MB ≈ 14 fps**，每帧约 32 KB。所以：

- 判断流好不好，**用 `--max-time 20`**，别用默认短超时
- 浏览器里打开也是一样：**先黑一下，8~10 秒后画面才出来**

**地址从哪来：不用手改。**

主控的 `/api/status` 里一直带着图传板的实际地址：

```json
"camera":{"reachable":true,"valid":true,"ip":"192.168.1.102",
          "name":"Maturo_CAM_1CDBD4979A2C","config_url":"http://192.168.1.102/",
          "stream_url":"http://192.168.1.102:81/"}
```

所以 `cam` 模式现在是**自动发现**的（问主控要 `camera.stream_url`，再用 launch 参数 `url:=` 传进去）：

```bash
# 【终端 D】不用改任何文件
bash 05_run_robot.sh cam
#   [INFO] 从机器人 192.168.1.103 自动发现相机：http://192.168.1.102:81/

# 手动指定
bash 05_run_robot.sh cam http://192.168.1.102:81/

# 【终端 B】验证
ros2 topic hz /camera/image_raw/compressed
```

**为什么不建议把 IP 写死在配置里**：图传板走 DHCP，路由器重启后 IP 可能变。
`http_video_publisher.yaml` 里的 `url` 已从作者默认的 `192.168.31.185` 改为本机实际的
`192.168.1.102`，那只是**兜底默认值**；真实使用靠 `cam` 模式的每次自动询问。

**建议**：在路由器里给**主控板**和**图传板**都做 **DHCP 静态绑定**，一劳永逸。

**两个相关判据**：

- `09_preflight.sh` 第 6 节现在会**自动比对**"配置里的相机地址"和"机器人上报的实际地址"，不一致直接报 WARN 并给出两种修法。
- RViz 里看相机会提示找不到 `camera_link` —— **URDF 里本来就没有这个坐标**，属预期现象。

---

### Q27：RViz 里点 `2D Pose Estimate` 之后，地图开始抖 / 车位置乱跳，为什么？

**因为 SLAM 与 Nav2（amcl）在同时跑，两条 `map→odom` 在打架。**

| | 行为 |
|---|---|
| `2D Pose Estimate` 按钮 | 发布 `/initialpose`（发布者：`rviz2`、`xuegecar_qt_gui`） |
| `slam_gmapping` | **不订阅** `/initialpose`（整包源码里根本没有）→ **建图时点它毫无作用** |
| `amcl`（Nav2 定位） | **订阅** `/initialpose`；**收到后才开始广播 `map→odom`** |

所以只要 amcl 是 `active`，你一点这个按钮就等于**把它叫醒**，它立刻开始发 `map→odom` ——
而 gmapping **也在发同一条 TF 边**。RViz 每帧读到哪条就用哪条，于是整个地图抖起来。

**实测证据**（车静止，两套同时跑，抓 6 秒 `/tf`，共 149 条 `map→odom`）：

```
map→odom 只在两组固定值之间交替：
    x = -1.1551, y = -0.1843, yaw = -35.572°   ← gmapping
    x = +0.0566, y = +0.1828, yaw = -62.679°   ← amcl
相邻帧 x 跳变 >5cm : 77/148 次，最大跳 121 cm
相邻帧 yaw 跳变 >3° : 77/148 次，最大跳 27.1°

区间统计（5.05 s）：x 跨度 1.21 m，y 跨度 0.37 m，yaw 跨度 27.1°
```

**判据**：`map→odom` 只在**两组固定值之间来回横跳**、而车是静止的 —— 两个广播者的签名。
（**噪声不长这样**：里程计/匹配噪声会给出很多个分散的值，不会聚成两组。）

同一现象还有第二个来源：**`/map` 也有两个发布者**
（`slam_gmapping` 发的实时图 + `map_server` 发的 `maps/room.yaml`），
RViz 的 Map 显示会在两张地图间切换 —— 看起来也是"地图在抖"。

**怎么查（一条命令）**：

```bash
# 【终端 B】车保持静止
bash 12_diag_jitter.sh
#   0b 节：直接读 /map 的发布者，>=2 就是冲突
#   2  节：自动判定 map→odom 是否「两组值交替」
#   ✓ 单发布者时不会误报（实测 top2 只占 46.8%、差值 5 mm → 判为正常）
```

手工查：

```bash
ros2 node list | grep -E 'amcl|slam_gmapping'      # 两个都在 → 冲突
ros2 topic info /map                              # Publisher count 应为 1
ps -eo pid,etime,cmd | grep -E 'slam_|component_container' | grep -v grep
```

**怎么修**：只留一套。

```bash
# ① 建图阶段：只跑 SLAM（别起 Nav2）
bash 05_run_robot.sh slam

# ② 地图保存后：在 SLAM 那个终端按 Ctrl+C 关掉它

# ③ 导航阶段：再起 Nav2 —— 此时 2D Pose Estimate 才有意义
bash 05_run_robot.sh nav-rviz
```

**已加固**：`05_run_robot.sh` 的 `slam` / `slam-toolbox` / `nav` / `nav-rviz` 四个模式
启动前都会自动检测，发现冲突就**拦截并解释原因**（`--force` 可跳过）；
`topics` 模式会报告当前定位栈与冲突状态。

> **顺带说明**：`nav` / `nav-rviz` 默认加载的是**作者示例地图**
> （`xuegecar_navigation2/maps/room.yaml`，参数里写的是 `turtlebot3_world.yaml` 风格）。
> 要导航自己的房间，需显式传图：
> `ros2 launch xuegecar_navigation2 navigation2_rviz.launch.py map:=$HOME/my_map.yaml`

---

### Q28：Qt 面板里「摄像头画面」一直是空白，但浏览器打开却有画面

**现象**

- 浏览器访问 `http://192.168.1.102:81/` —— 有画面 ✅
- Qt 面板右上角「摄像头画面」卡片 —— 一直停在灰色的
  `等待 /camera/image_raw/compressed` ❌

**原因：这两条是完全不同的两条路，别把它们当成一回事**

```
浏览器 ──直连──> 图传板 MJPEG (http://<相机IP>:81/)          ← 不经过 ROS，所以一直好用
Qt 面板 ──ROS话题──> /camera/image_raw/compressed ──> 由 http_video_publisher 节点提供
```

浏览器是**直连图传板**看流，跟 ROS 一点关系都没有；而 Qt 订阅的是 ROS 话题。
**必须有一个 `http_video_publisher` 节点把 MJPEG 拉下来、转成 ROS 的 CompressedImage 发出来**，
Qt 才有东西可显示。当时那个节点根本没在跑 —— 这就是空白的直接原因。

**顺带挖出来的第二个坑：Qt 的「启动命令」按钮全是废的**

既然缺节点，手动点面板上的「摄像头 → 启动」不就行了？结果点了报错：

```
Package 'xuegecar_camera' not found
```

查到 `src/xuegecar_qt_gui/src/main_window.cpp` 的 `rosShellPrefix()`，它 source 的是
**作者机器上的工作空间路径**：

```cpp
// 原来（错的）
"if [ -f /home/xuegeros/microros_ws/install/setup.bash ]; then source ...; fi && "
"if [ -f /home/xuegeros/xuegeros_ws/install/setup.bash ]; then source ...; fi && "
```

`/home/xuegeros/` 在你的机器上根本不存在，两个 `[ -f ]` 判断全部为假 ——
**既不报错、也没 source 到本机工作空间**。于是 `ros2` 命令本身能找到（系统包），
但 `xuegecar_*` 这些包一个都找不到。**四个启动按钮（Micro-ROS / 底层驱动 / 摄像头 / SLAM+Nav2）
因此全部失效**。

> 排查时容易走偏的一点：`bash -lc` 本身**没问题**。
> 实测 `bash -lc 'source /opt/ros/humble/setup.bash && ros2 ...'` 能正常工作；
> 真正的病根只有「工作空间路径写死成作者的家目录」这一个。
> （`~/.bashrc` 第 6~9 行确实有个非交互早退守卫，但它只影响 `.bashrc` 后面的内容，
> 不影响你显式 source 的那条命令。）

**已修复内容**

1. `rosShellPrefix()` 改为**自动探测**，不再写死用户名：
   `$XUEGECAR_WS` → `$HOME/leap_ros_ws` → `$HOME/xuegeros_ws` → `$HOME/ros2_ws`，
   谁有 `install/setup.bash` 就 source 谁；同时显式导出 `ROS_DOMAIN_ID` 和
   `RMW_IMPLEMENTATION`（防止 Qt 从桌面启动时 RMW 与终端不一致，导致互相看不到话题）。
2. `bash -lc` 改为 `bash -c`（少读一层配置文件，更快更可控）。
3. 「摄像头」那一项**默认在面板启动 1.5 秒后自动拉起**，并在面板里加了开关
   「启动面板时自动打开摄像头」。没接图传板时取消勾选即可，免得日志里反复重连。
4. `slam_nav2` 等其余三项保持手动点。

**怎么用**

```
# 方式一：点 Qt 面板
bash 05_run_robot.sh qtgui          # 打开面板 → 相机默认自动启动
                                    # 取消勾选「启动面板时自动打开摄像头」可关闭

# 方式二：在终端手动起（推荐，日志更清楚）
bash 05_run_robot.sh cam            # 自动从机器人问出相机地址
```

⚠ **相机要预热**：图传板是拉流后才开始出帧，**约 8~10 秒**后 Qt 才会出现第一帧，
别以为没反应就反复重启。

**验证**

```bash
# ① 确认话题有发布者（不是「无」）
ros2 topic info /camera/image_raw/compressed -v | grep -E "Publisher count|Node name"

# ② 确认帧率不为 0
ros2 topic hz /camera/image_raw/compressed

# ③ 浏览器对照（这条能看、Qt 还不行，就说明是 ROS 侧的问题，不是相机坏了）
xdg-open http://192.168.1.102:81/
```

> 补一句：`/usr/bin/python3` 里 **cv2 是有的**（opencv 4.11.0），
> 所以「节点起不来」不会是因为缺 OpenCV。
> 但如果哪天用 `python3 -c "import cv2"` 报 `ModuleNotFoundError`，先 `which python3` 看一眼 ——
> 可能命中的是别的 Python 环境（比如 conda），而不是 ROS 用的那个。

---

### Q29：车转弯时方向越转越偏 / 建图旋转错位 —— 用 EKF 把 IMU 接进里程计

**现象**

直行还好，**一转弯方向就明显偏**；建图时房间的墙角会被"扭"成弧形；
`12_diag_jitter.sh` 里 `motion.yaw` 与 `imu.yaw` 两路偏差越跑越大。

**根因（固件层）**

主控固件的里程计偏航是**纯轮速差积分**：

```cpp
// leap_firmware/leap_low_v1/main/control/motion_controller.cpp
odom_yaw_ += local_vw * dt;      // local_vw 来自左右轮速差
```

轮子一打滑、或者轮距参数不准，这个角度就会快速跑偏。
更可惜的是 —— **固件其实已经把 IMU 偏航算好了**（`imu_yaw_rel_`，也通过
`/imu` 话题发出来了），只是**从来没喂进里程计**。

> 顺带一个已知不一致：固件 `kTrackWidth = 150 mm`，而 URDF 里两轮摆的是 200 mm。
> 轮速差算偏航的误差会和这个直接挂钩（差 33%）。

**做法：不改固件，在上位机做互补融合**

```
轮子 ──> 提供「前进速度 vx」   （直接测量，不受偏航误差污染）
陀螺 ──> 提供「偏航角速度 vyaw」（直接测量，远好于轮速差分）
        ↓
    robot_localization (EKF) ──> 自己积分出 x / y / yaw
```

固件那份被污染的位置和角度**一概不用**。

```
bash 05_run_robot.sh ekf            # 一条命令全搞定
```

这条命令会：① 起 micro-ROS Agent ② 起 IMU 协方差修正 + EKF
③ 起机器人模型时带上 `publish_tf:=false`。

**⚠⚠ 三个必须知道的关键点（踩过就不想再踩）**

**① 固件发的 IMU 协方差是「无效」，EKF 会直接丢弃 —— 这是最坑的一步**

固件 `microros_task.cpp` 里把三个协方差数组的第 0 位都写成了 `-1.0`：

```c
s_imu_msg.orientation_covariance[0]         = -1.0;
s_imu_msg.angular_velocity_covariance[0]    = -1.0;
s_imu_msg.linear_acceleration_covariance[0] = -1.0;
```

在 `sensor_msgs/Imu` 的约定里，`covariance[0] == -1` 表示**该字段无效**。
robot_localization 严格遵守这条约定 —— 它会**直接跳过这些测量值**。
表现极具迷惑性：**EKF 起来了、参数也写了 `/imu`、一条报错都没有，
但状态估计里完全没有 IMU 的贡献**。

解决：新增 `xuegecar_imu` 包里的 `imu_covariance_fixer` 节点，
订阅 `/imu` → 补齐协方差 → 转发到 `/imu/data`，EKF 订阅 `/imu/data`。
**纯上位机，不用重新烧录固件。**
（哪天固件把协方差修好了，把 `ekf.yaml` 里的 `imu0` 直接改成 `/imu` 即可。）

**② 同一条 TF 只能有一个发布者 —— 否则机器人会来回跳**

`odom→base_footprint` 原来由 `xuegecar_bringup` 广播。
启用 EKF 后这条 TF 必须**让给 EKF 独占**，不然两边同时发（底盘 1000 Hz、EKF 30 Hz），
你在 RViz 里看到的就是机器人在两组位姿之间横跳 —— 和 Q27「SLAM 与 Nav2 抢
`map→odom`」是**完全同一类问题**。

这就是为什么 `xuegecar_bringup` 新增了 `publish_tf` 参数、`ekf` 模式自动传 `false`。
单独手动启动时别忘掉：

```bash
ros2 launch xuegecar_bringup xuegecar_bringup.launch.py publish_tf:=false
```

**③ `base_link_frame` 必须写 `base_footprint`，不能写 `base_link`**

URDF 里是 `base_footprint → base_link`（由 robot_state_publisher 发布）。
如果 `ekf.yaml` 里也写 `base_link`，`base_link` 就同时有两个父节点，**整棵 TF 树会炸**。

**改了哪些文件**

| 文件 | 改动 |
|------|------|
| `xuegecar_navigation2/config/ekf.yaml` | 重写：`two_d_mode`、`base_link_frame: base_footprint`、只融合 odom 的 `vx` + IMU 的 `vyaw` |
| `xuegecar_navigation2/launch/ekf_localization.launch.py` | **新增**：起 IMU 修正 + EKF，自动对齐 IMU 话题 |
| `xuegecar_imu/`（新包） | **新增**：`imu_covariance_fixer` —— 补协方差后转发 |
| `xuegecar_bringup/src/xuegecar_bringup.cpp` | 新增 `publish_tf` 参数（默认 `true`，保持老行为） |
| `xuegecar_bringup/launch/xuegecar_bringup.launch.py` | 新增 `publish_tf` launch 参数 |
| `05_run_robot.sh` | 新增 `ekf` / `fusion` 模式 |

> 改动全部是**向后兼容**的：不加 `ekf`、不改任何参数，行为和你以前跑 `core` 一模一样。

**验证**

```bash
# ① 修正确实生效：协方差应该是 0.005 / 0.0005 / 0.05，不再是 -1
ros2 topic echo /imu/data --once | grep -A4 covariance

# ② EKF 在 30 Hz 输出
ros2 topic hz /odometry/filtered

# ③ 关键验证：odom→base_footprint 只能有一个来源
ros2 topic info /tf -v | grep "Node name"
#    期望看到 ekf_filter_node；机器人静止时 tf2_echo 的位置应该是 0 附近
ros2 run tf2_ros tf2_echo odom base_footprint

# ④ 对比改造前后：转弯跑一圈，看 motion.yaw 与 imu.yaw 是否还持续分离
bash 12_diag_jitter.sh
```

**两个要知道的行为变化**

1. **里程计原点会归零**。EKF 以「它启动的那一刻」作为 odom 零点，
   而固件 `/odom` 是从机器人上电开始累积的。所以启动 EKF 后，
   `odom→base_footprint` 会从 0 开始 —— 这是里程计的**正常行为**（每次启动都归零），
   对 `gmapping` 建图和 Nav2 没有影响（它们用 `map→odom` 吸收这个偏移）。
   但如果你有**事先标定好的绝对坐标导航点**，需要重新对照一次。

2. **EKF 只在 IMU 和里程计数据都到位后才输出 TF**。
   如果 Agent 会话没建立，`/imu` 没数据，TF 就不会出现 —— 这不是 EKF 坏了，
   先跑 `bash 05_run_robot.sh topics` 确认 `/imu`、`/odom` 都在。

> **什么时候不该用 `ekf`？**
> 只想最小改动跑通全链路时，继续用 `core` 就好。
> EKF 是给「转弯漂移已经影响建图/导航」准备的增强项，不是必须项。

---

## 七、脚本清单

| 脚本 | 作用 | sudo |
|------|------|------|
| `01_install_ros2_humble.sh` | 安装 ROS 2 Humble + 全部依赖 + 串口权限 | ✅ |
| `02_build_workspace.sh` | 编译 ROS 2 工作空间（支持 `--clean`） | ❌ |
| `03_install_espidf.sh` | 安装 ESP-IDF v5.5.3 + esp32s3 工具链 | ❌ |
| `04_flash_firmware.sh` | 编译烧录 ESP32-S3 固件 | ❌ |
| `05_run_robot.sh` | 启动机器人各功能：`core`（链路，日志写 `/tmp/leap_ros_agent.log`）/ **`ekf`（链路 + IMU 融合，转弯更稳，自动关掉底盘 TF）** / `reset`（**一键复位机器人 + 同步 Agent IP**）/ `topics`（**看会话状态 + 话题**）/ agent/bringup/slam/nav/**cam（自动发现相机地址）**… | ❌ |
| `06_setup_lidar_socat.sh` | 替代 launch 中硬编码密码的 `/dev/lidar` 虚拟串口方案 | ✅ |
| `07_fix_rosdep.sh` | 修复 rosdep 走 GitHub 导致的 429 / 更新失败 | ✅ |
| `08_install_ydlidar_sdk.sh` | 编译安装 YDLidar-SDK（`ydlidar_ros2_driver` 的必需依赖） | ❌ / `--system` 需 ✅ |
| `09_preflight.sh` | **运行前预检**：本机 IP、环境/串口/端口/相机 + **自动扫描发现机器人、核对 Agent IP / 通信模式 / 相机地址一致性** | ❌ |
| `10_diag_portal.sh` | **配网页诊断**：自动判别连的是主控板还是图传板，给出正确的配网页地址 | ❌ |
| `11_fix_serial_perm.sh` | **串口权限修复**：重写 udev 规则（CH340 按 vendor 通配）+ reload + 重新触发 + 验证 | ✅ |
| `12_diag_jitter.sh` | **抖动专项诊断**（需机器人静止）：**0b 节先查定位栈冲突（`/map` 发布者数 ≥2）**，再量 `odom→base`／`map→odom` 抖动（含「两组值交替」判定）、固件 `motion.yaw` vs `imu.yaw` 漂移、`/scan` 零值质量，并直接判定抖动来自哪一层 | ❌ |
| `99_check_env.sh` | 环境自检，输出 PASS/WARN/FAIL | ❌ |

**文档：**

| 文件 | 内容 |
|------|------|
| `新手全流程指南.md` | **第一次连机器人看这个**：接线 → 烧录 → 配网 → 启动 → 验证 → 遥控/建图/导航。开头有 **[终端分工表](#)**（A 链路／B 检查／C 遥控／D 建图导航／E 烧录），每步都标明在哪个终端执行 |
| `参数调参索引.md` | **想改某个参数就看这个**：全项目参数（脚本开关 / 相机 / Qt 面板 / RViz / gmapping / Nav2 / 雷达 / EKF / URDF / 主控固件 / 图传固件）的**文件:行号 + 改完要不要重编译/重烧**，附「改了没反应」自查表 |
| `README.md` | 本文件。环境安装、架构说明、关键配置、故障排查 Q1~Q29 |

---

## 八、参考资源

- 项目仓库：https://github.com/czu963889306-dev/leap_ros2
- ROS 工作空间：https://github.com/czu963889306-dev/leap_ros_ws
- 主控固件：https://github.com/czu963889306-dev/leap_ros_mcu_driver
- WiFi 图传：https://github.com/czu963889306-dev/esp32_s3_wifi_camera
- 学习文档：https://my.feishu.cn/wiki/Qzl8wFIfKiksMskyEqMc02sYnXf
- 视频教程：https://www.bilibili.com/video/BV1nNNb6cER7/
- 交流 QQ 群：`1055265929`

---

*本指南由环境配置脚本自动生成，脚本位于 `setup/` 目录。*
