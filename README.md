# custom-package 分支说明

本分支为 **LEAP_ROS / 学哥ROS 二驱智能车本地完整资源包**（个人整理的收藏/部署版），
基于上游 `czu963889306-dev/leap_ros2` 项目重新整理，并补充了源码、固件与部署脚本。

> 上游原仓库：https://github.com/czu963889306-dev/leap_ros2（Apache-2.0，仅含硬件资料）

## 与上游 main 的差异

- 上游 `main` 只含 `硬件/`（5.原理图 / 7.BOM / 8.嘉立创工程文件 / 9.3D打印外壳）
- 本分支为**完整资源包布局**：

| 目录 | 内容 | 对应上游 |
|------|------|----------|
| `1.源码` | leap_cam 摄像头工程 / leap_low_v1 下位机固件（tar）/ xuegeros_ws ROS 工作空间（zip） | 新增 |
| `2.固件` | cam_v1.0.bin / leap_ros_v1.5.bin 已编译固件 | 新增 |
| `3.原理图` | 主控板 / 图传摄像头 | 硬件/5.原理图 |
| `4.嘉立创工程文件` | LEAP_CAM / LEAP_ROS 工程 | 硬件/8.嘉立创工程文件 |
| `5.3D打印外壳` | 开源外壳 | 硬件/9.3D打印外壳 |
| `6.BOM` | 物料清单 | 硬件/7.BOM |
| `8.安装文档` | LEAP_ROS 安装教程 | 新增 |
| `setup` | Linux 部署脚本 + 新手指南 / 参数调参索引 | 新增 |

- `xuegeros_ws` 源码源自 `gitee.com/czulcl/leap1`（master `a456afd v1.0`），为学哥ROS 定制版
- 部署脚本与文档为本包定制内容（MIT）

## 用法

```bash
git clone -b custom-package https://github.com/gaibuhui/leap_ros2.git
```

硬件文件可直接打开；软件部分见 `setup/新手全流程指南.md`。
