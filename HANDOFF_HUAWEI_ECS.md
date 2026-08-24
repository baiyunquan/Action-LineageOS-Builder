# 华为云 ECS 构建交接文档

目标是在华为云 x86_64 ECS 上构建 LineageOS 15.1（产品
`lineage_alice-userdebug`）。本机 ARM64 只负责同步和传输；两台美国 VPS
各保存一个压缩卷，华为云端从两个 HTTPS 地址并行下载后按顺序拼接。

## 0. 当前状态和硬性约束

源码目录：

```text
/mnt/usb/lineage15.1-source
```

当前 `repo sync` 尚未完成时，不要启动传输。传输脚本会检测
`.repo/repo/main.py sync` 并主动退出。同步结束后检查：

```bash
pgrep -af '/mnt/usb/lineage15.1-source/.repo/repo/main.py' || true
test -d /mnt/usb/lineage15.1-source/.repo
test -f /mnt/usb/lineage15.1-source/.repo/local_manifests/alice.xml
test -d /mnt/usb/lineage15.1-source/device/huawei/alice
test -d /mnt/usb/lineage15.1-source/vendor/huawei/alice
test -d /mnt/usb/lineage15.1-source/kernel/huawei/alice
```

不要在归档前修改源码树。归档保留 `.repo`、Git 历史、local manifest 和
Git LFS 对象，避免 ECS 再次联网同步。

## 1. 本机流式分成两卷并上传

安装一次工具：

```bash
sudo apt-get update
sudo apt-get install -y zstd tar coreutils openssh-client
```

两台 VPS：

| 卷 | SSH | 网站 |
|---|---|---|
| volume 0 | `liaic@153.75.235.35 -p 50922` | `https://extra.liaic.cyou` |
| volume 1 | `liaic@74.50.72.148 -p 50922` | `https://liaic.cyou` |

执行：

```bash
cd /home/liaic/Documents/backup_cam-tl00_20260721
SRC=/mnt/usb/lineage15.1-source \
VPS1_HOST=153.75.235.35 VPS1_DOMAIN=extra.liaic.cyou \
VPS2_HOST=74.50.72.148 VPS2_DOMAIN=liaic.cyou \
./lineage_build/scripts/stream-source-two-volumes.sh
```

脚本分两次遍历源码：

1. 第一次是 `tar | zstd | wc -c`，只测量压缩流大小，不创建本地归档。
2. 第二次重新压缩，使用两个 FIFO 和两条 SSH，同时把前半卷写到旧 VPS、
   后半卷写到新 VPS。

本机不会保存压缩包或卷文件；临时 FIFO 在脚本退出时清理。两卷大小最多相差
1 字节。脚本会分别检查两台 VPS 的可用空间（每台需要约半卷加
`RESERVE_GIB`，默认 2 GiB）。为节省时间，本流程不计算或传输 SHA256 校验文件，
仅检查 SSH、远端文件写入和最终文件非空。默认每台约有 32--34 GiB 可用空间，
仍应以脚本的实时检查为准。

## 2. 两台 VPS 发布静态下载路径

上传完成后，在每台 VPS 各执行一次 root 配置。先复制脚本：

旧 VPS：

```bash
scp -P 50922 lineage_build/scripts/install-vps-download-location.sh \
  liaic@153.75.235.35:/home/liaic/
ssh -p 50922 liaic@153.75.235.35
sudo -i
NGINX_SITE=/etc/nginx/sites-enabled/extra.liaic.cyou \
  bash /home/liaic/install-vps-download-location.sh
```

新 VPS：

```bash
scp -P 50922 lineage_build/scripts/install-vps-download-location.sh \
  liaic@74.50.72.148:/home/liaic/
ssh -p 50922 liaic@74.50.72.148
sudo -i
bash /home/liaic/install-vps-download-location.sh
```

脚本会把 `/home/liaic/lineage-upload` 中本机上传的文件移动到
`/srv/lineage-downloads`，在现有 Nginx server 中加入
`/lineage-source/` 静态 location，备份配置，执行 `nginx -t` 后 reload。
发布地址应分别是：

```text
https://extra.liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-0
https://liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-1
```

源码包默认公开；如果不希望公开，需在 Nginx location 中自行增加认证或使用
随机路径。脚本不会自动获取 sudo 密码，也不会覆盖现有 MkDocs 反向代理。

## 3. 华为云 ECS 并行下载、校验、解压

ECS 建议使用 Ubuntu 22.04 x86_64、16 vCPU、32 GiB RAM，额外 EVS 挂载到
`/work`，源码、`out` 和 ccache 共预留至少约 300 GiB。

安装下载工具：

```bash
sudo mkdir -p /work
sudo apt-get update
sudo apt-get install -y curl zstd tar coreutils
```

把 `lineage_build/scripts/download-source-two-vps.sh` 复制到 ECS 后执行：

```bash
PART0_URL=https://extra.liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-0 \
PART1_URL=https://liaic.cyou/lineage-source/lineage15.1-source.tar.zst.part-1 \
DEST=/work DOWNLOAD_DIR=/work/lineage-transfer \
bash ./lineage_build/scripts/download-source-two-vps.sh
```

脚本会启动两条 curl 并行下载，不下载或计算 SHA256；下载完成后直接按 volume 0、
volume 1 顺序拼接 zstd 流并解包到 `/work/lineage15.1-source`。默认保留下载卷，
便于失败重试；确认解包成功且空间紧张时可用 `KEEP_PARTS=0` 清理两个下载文件。

整理为构建脚本要求的目录：

```bash
test -d /work/lineage15.1-source/.repo
test -f /work/lineage15.1-source/.repo/local_manifests/alice.xml
sudo mkdir -p /work/lineage-build
sudo mv /work/lineage15.1-source /work/lineage-build/workspace
sudo chown -R <构建用户>:<构建用户> /work/lineage-build
```

## 4. ECS 上 Codex 构建

在 ECS 上运行 Ubuntu 初始化脚本（Mihomo YAML 留在脚本编辑区，按需填写）：

```bash
cd /path/to/backup_cam-tl00_20260721
sudo bash lineage_build/scripts/setup-ubuntu2204-buildhost.sh
sudo -iu <构建用户>
codex login
```

ECS 上的 Codex 配置位于 `/home/ubuntu/.codex/config.toml`，已默认使用
`danger-full-access`、`approval_policy = "never"`、代理登录环境和
`/home/ubuntu/Action-LineageOS-Builder` trusted 项目。对应模板见
[`ECS_CODEX_CONFIG.toml`](ECS_CODEX_CONFIG.toml)。

源码已经传输完成时，不要再执行 `repo sync`：

```bash
cd /path/to/Action-LineageOS-Builder
./scripts/build-local.sh \
  --workdir /work/lineage-build \
  --skip-sync \
  --jobs 16 \
  --ccache-size 32G \
  --checkpoint-interval 15m
```

构建容器默认名为 `lineageos-15.1-build`，不会自动删除；脚本每 15 分钟将容器
可写层提交为 `lineageos-15.1-builder:checkpoint`，阶段和提交日志位于
`/work/lineage-build/checkpoints/`。源码、`out/`、ccache 和日志都是 `/work` 上
的 bind mount，不会复制到系统盘镜像层。失败后直接续跑：

```bash
./scripts/build-local.sh --workdir /work/lineage-build --skip-sync \
  --resume --jobs 16 --ccache-size 32G
```

若容器被手动删除但 checkpoint 镜像仍在，`--resume` 会从该镜像新建容器；不要
删除 `/work/lineage-build/workspace` 或 `/work/lineage-build/ccache`。

产物通常位于：

```text
/work/lineage-build/workspace/out/target/product/alice/
```

首次失败时保留源码、`out` 和 ccache，修复后继续构建，不要删除整个工作树。

## 5. 故障判断

| 现象 | 处理 |
|---|---|
| 脚本提示 repo sync 仍运行 | 等同步结束后重新运行；不会产生远端卷 |
| 某卷下载中断或大小为 0 | 只重新传输对应 VPS 的卷，确认磁盘和 SSH 没有中断 |
| zstd/tar 解包失败 | 删除 ECS 不完整卷后重新下载两卷 |
| HTTPS 404 | 检查对应 VPS 是否执行 root 安装脚本、Nginx 配置和 reload |
| LFS 文件是文本指针 | 在源码树执行 `git lfs install`，再对对应项目执行 `git lfs pull` |
| ECS 空间不足 | 增大 EVS；不要删除 `.repo` 以节省空间 |

## 6. 完成后清理

验证 ROM 并把产物下载到安全位置后，再分别删除两台 VPS 的
`/srv/lineage-downloads`，清理 ECS 的 `/work/lineage-transfer`，最后释放
临时 ECS、EIP 和 EVS，避免继续计费。
