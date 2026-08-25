# 本地编译方案

在自有 x86_64 Linux 机器上编译 LineageOS 15.1（CAM-TL00 / 通用 hi6210sft），
作为 GitHub Actions 路线之外的另一条路径。

> ⚠ **本方案尚未实跑验证。** 所有脚本只做过语法检查（`bash -n`）。
> 但其中已经吸收了 CI 路线上实测踩到的四个坑（见下文「已知坑」），
> 那部分是真实验证过的。

---

## 为什么要有本地方案

CI 路线有两个硬约束，本地全都没有：

| | GitHub Actions | 本地 |
|---|---|---|
| 单次时长 | **6 小时硬上限** | 无限制 |
| `out/` 是否保留 | **不保留**（runner 用完即毁） | 保留 |
| 重跑语义 | ccache 预热后**从头再来** | **真正的增量编译** |
| 源码同步 | 每次重新 sync（约 5-10 分钟） | 只需一次 |
| 并行度 | 4 核固定 | 由你的机器决定 |

关键差异是 `out/` 是否保留。CI 上每次重跑都要把 92680 个目标重新走一遍
（只是 C/C++ 部分能命中 ccache）；本地改一行设备树重编，通常几分钟就完事。

**结论：调设备树、反复迭代 → 用本地。只是想要一个产物 → CI 也行。**

---

## 环境要求

| 项目 | 要求 | 说明 |
|---|---|---|
| 架构 | **必须 x86_64** | 树上所有预编译工具链（clang/gcc/JDK）都是 x86_64 ELF；arm64 机器（如本项目所在的树莓派）无论多大内存都跑不了 |
| 磁盘 | ≥ 300 GB | 源码约 30 GB + `out/` 约 60 GB + ccache 默认 50 GB |
| 内存 | ≥ 16 GB | 低于 16 GB 建议调低 `--jobs` 或加 swap，否则易被 OOM kill |
| 系统 | 任意现代 Linux | 编译在 `ubuntu:18.04` 容器内进行，宿主机版本不限 |
| 依赖 | docker、git、curl、python3 | `repo` 脚本会自动下载 |

宿主机**不需要**装 openjdk-8 或 python2 —— 那些在容器里。

---

## 快速开始

```bash
git clone https://github.com/baiyunquan/Action-LineageOS-Builder
cd Action-LineageOS-Builder

# 完整编译（首次会拉约 30GB 源码，并构建一次容器镜像）
./scripts/build-local.sh

# 改完设备树后增量重编，跳过同步；每 15 分钟保存一次 Docker checkpoint
./scripts/build-local.sh --skip-sync --checkpoint-interval 15m

# 如果编译失败，保留的容器和 /work 上的 out/、ccache 可直接续跑
./scripts/build-local.sh --skip-sync --resume

# 进容器手动调试
./scripts/build-local.sh --shell
```

常用参数：

```
--workdir DIR      构建根目录，默认 ./build-local
--jobs N           并行度，默认 nproc
--ccache-size N    默认 50G
--target NAME      make 目标，默认 bacon（完整 zip）
--native           不用 docker，直接在宿主机编译（需自备 JDK8 + python2）
--skip-sync        跳过 repo sync
--shell            进入容器 shell 而不是编译
--resume           继续上一次保留的容器；没有容器时使用 checkpoint 镜像
--checkpoint-interval DURATION
                   定时 docker commit，默认 15m；例如 10m、30m
--checkpoint-image IMAGE
                   checkpoint 镜像标签，默认 lineageos-15.1-builder:checkpoint
--container-name NAME
                   容器名，默认 lineageos-15.1-build
--no-checkpoint    关闭定时 docker commit（仍保留容器和 /work 状态）
```

产物：`build-local/workspace/out/target/product/alice/lineage-15.1-*.zip`

### 断点与磁盘位置

`build-local.sh` 不再使用 `--rm`：编译容器会保留，失败后可用 `--resume` 重新
执行原命令。驱动器在后台读取 `checkpoints/current-stage`，并按间隔执行：

```text
docker commit --no-pause lineageos-15.1-build lineageos-15.1-builder:checkpoint
```

阶段和提交记录写在 `build-local/checkpoints/`。需要注意 Docker commit **不会
包含 bind mount 的内容**；这是有意的：源码、`out/`、ccache 和 checkpoint 日志
都位于 `--workdir`（在华为云主机上应为 `/work/...`），本来就会跨容器保留，且不
会被复制进系统盘上的镜像层。checkpoint 镜像只保存容器自身的可写层和环境状态。

失败后查看状态并续跑：

```bash
cat /work/lineage-build/checkpoints/current-stage
tail -n 20 /work/lineage-build/checkpoints/history.log
tail -n 20 /work/lineage-build/checkpoints/commits.log
./scripts/build-local.sh --workdir /work/lineage-build --skip-sync --resume \
    --jobs 16 --ccache-size 32G
```

脚本不会自动删除旧容器或 checkpoint 镜像；确认不再需要后再手动执行
`docker rm lineageos-15.1-build` 和 `docker image rm lineageos-15.1-builder:checkpoint`。

---

## 各文件职责

| 文件 | 运行位置 | 作用 |
|---|---|---|
| `scripts/build-local.sh` | 宿主机 | 总驱动：预检 → 同步 → 编译 → 门禁 |
| `docker/Dockerfile` | — | `ubuntu:18.04` 构建镜像，依赖只装一次 |
| `scripts/build-inner.sh` | 容器内 | 纯编译步骤（envsetup / lunch / make） |
| `scripts/sync-source.sh` | 宿主机 | 与 CI 共用：repo 同步（保持源码干净） |
| `scripts/apply-source-patches.sh` | 宿主机 | 同步后应用全部补丁并校验 vendor blob |
| `scripts/apply-device-patches.sh` | 宿主机 | 与 CI 共用：设备树三处改动 |
| `scripts/apply-alice-patcher.sh` | 宿主机 | 与 CI 共用：幂等补丁 |
| `scripts/verify-rom.py` | 宿主机 | 与 CI 共用：产物门禁 |

同步与打补丁**完全复用 CI 的脚本**，所以两条路线产出的树是一致的。
只有「编译」这一步分成两份：CI 版
（`build-in-container.sh`，带超时与续跑）和本地版（`build-inner.sh`，只负责编译）。

### 为什么编译步骤要分两份

CI 版里的 `timeout 290m` + 退出码 75 + ccache 保存，**纯粹是为了对付 6 小时
上限和临时 runner**。本地驱动器通过保留容器、bind mount 和定时 Docker
checkpoint 实现断点续跑，而 `build-inner.sh` 仍只负责一次 envsetup/lunch/make 流程。

---

## 已知坑（CI 上实测踩过，已写进脚本）

这四条是真金白银的 CI 运行换来的，本地方案里已经全部规避：

### 1. bionic 的 apt 源与网络位置

Ubuntu 18.04 的 APT 源通过一次性源列表配置。默认使用官方
`archive.ubuntu.com`（失败时回退 `security.ubuntu.com`），适合微软/海外 runner；
在大陆网络中可设置 `USE_CN_MIRRORS=1`，再按“华为云 → 阿里云”顺序尝试国内镜像。
两个模式都保留 `bionic-security`，且不会改写宿主机或基础镜像的永久 apt 配置。

APT 启动阶段使用 HTTP，是因为最小化 `ubuntu:18.04` 镜像尚未安装 CA 根证书；
依赖列表随后会安装 `ca-certificates`。

Android/Lineage 源码本身仍从 GitHub 获取；目前没有可验证的华为云或阿里云
完整 Git/LFS 镜像，不能把 GitHub 地址盲目替换成第三方镜像。

### 2. `set -u` 会打断 `lunch`

`envsetup.sh`、`lunch` 和构建过程都会读未定义变量。在 `source envsetup.sh`
之后恢复 `set -u`，`lunch` 会直接死在 `TOP: unbound variable`。

因此 `build-inner.sh` 里 `set +u` 之后**不再恢复**。

### 3. `mka` 是 shell 函数，不能被 exec

`mka` 由 `envsetup.sh` 定义，不是可执行文件。CI 里 `timeout ... mka` 直接报
`failed to run command 'mka': No such file or directory`（退出码 127）。

两条路线统一改用 `make -j N bacon` —— `bacon` 是 `vendor/lineage/build/tasks`
里的真实 make 目标，`lunch` 已经导出了 make 需要的全部环境。

### 4. Jack server 在容器里起不来

LineageOS 15.1 会尝试启动 Jack（旧 Java 工具链）。Jack 通过本地 TLS socket
与后台服务通信，证书首次运行时生成，在容器里会失败：

```
FAILED: setup-jack-server
Jack server failed to (re)start
SSL error when connecting to the Jack server
```

Jack 在 Android 8.0 就已废弃，8.1 用 javac/d8 完全没问题。
`Dockerfile` 和 `build-inner.sh` 都设了 `ANDROID_COMPILE_WITH_JACK=false`。

---

## 预期耗时

参考：CI 上 4 核 runner 从零编译，跑到约 5% 用了 8 分钟，
之后连续编译约 2 小时（该次最终未确认是否产出 zip，见 README 的状态说明）。

| 场景 | 4 核 | 16 核 |
|---|---|---|
| 首次 repo sync | 5-15 分钟 | 5-15 分钟（受带宽限制） |
| 构建容器镜像 | 3-5 分钟（仅一次） | 同左 |
| 首次全量编译 | 3-6 小时 | 1-2 小时 |
| 改设备树后增量 | 数分钟 | 数分钟 |

关闭了 dexpreopt（`WITH_DEXPREOPT := false`），这既省编译时间，也让 system
镜像能塞进**只有 2684354560 字节、毫无余量**的 p38 分区。

---

## 产物门禁

编译结束后 `build-local.sh` 会自动跑 `verify-rom.py`，期望值全部来自本机备份
实测（不是抄设备树）：

- `system.img` ≤ `2684354560`（p38 正好装满，超了必然刷失败）
- `boot.img` ≤ `25165824`，且 kernel `0x07480000` / ramdisk `0x0f000000` /
  tags `0x09e00000` / pagesize 2048
- `dt_size` 应为 0（DTB 来自未被触碰的 dtimage p29）
- zip 内 updater-script 必须接受 `hi6210sft`

这个脚本本身**验证过**：已知可用的 LineageOS 14.1 `boot.img` 通过全部检查；
把 kernel 地址改成 `0x07487800` 后正确失败退出 1。

---

## 排错

**`This host is aarch64`** —— 预期行为，换 x86_64 机器。

**`cannot talk to the docker daemon`** —— `sudo usermod -aG docker $USER`
后重新登录。

**编译中途被 OOM kill** —— 降低 `--jobs`（如 16GB 内存用 `--jobs 4`），
或加 swap。

**想从干净状态重来** —— 删掉 `build-local/workspace/out`，
保留 `build-local/ccache` 可显著加快重编。

**磁盘不够** —— `--ccache-size 20G` 可省一些；再不够就只能换盘，
`out/` 那 60GB 压不下去。

---

## 刷机

与 CI 产物完全相同，见 [README.md](README.md#刷机) 一节。要点不变：

1. 先备份 `boot` / `recovery`
2. 用 **alice 版 TWRP**（上报 `ro.product.device=hi6210sft`，这是断言能过的原因）
3. 从 EMUI 6 跨版本升级必须 `Wipe → Format Data`
4. **不要碰 `oeminfo` (p8)，含 IMEI**
