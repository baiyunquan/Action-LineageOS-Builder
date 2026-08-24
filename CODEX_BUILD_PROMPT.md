# ECS Codex 构建提示词

你在华为云 Ubuntu 22.04 x86_64 ECS 上工作。先确认：

```bash
findmnt /work
df -h /work /
docker info --format '{{.DockerRootDir}}'
```

源码、构建输出、ccache、checkpoint 日志和 Docker 数据必须位于 `/work`；若
`/work` 不是额外 EVS 或 DockerRootDir 不是 `/work/docker`，先停止并修复，不能
把大文件写入系统盘。

源码已由两个 VPS 下载并解包到 `/work/lineage-build/workspace`。不要执行
`repo sync`，先确认 `.repo` 存在，然后运行：

```bash
cd /home/ubuntu/Action-LineageOS-Builder
./scripts/build-local.sh \
  --workdir /work/lineage-build \
  --skip-sync \
  --jobs 16 \
  --ccache-size 32G \
  --checkpoint-interval 15m
```

构建脚本会保留 `lineageos-15.1-build` 容器，并定期提交
`lineageos-15.1-builder:checkpoint`。源码、`out/` 和 ccache 是 `/work` 上的
bind mount；Docker commit 不会复制这些大目录，这是预期行为。查看阶段：

```bash
cat /work/lineage-build/checkpoints/current-stage
tail -n 30 /work/lineage-build/checkpoints/history.log
tail -n 30 /work/lineage-build/checkpoints/commits.log
```

若构建返回非零，先保留容器和 `/work`，修复具体错误后用同一目录续跑：

```bash
./scripts/build-local.sh --workdir /work/lineage-build \
  --skip-sync --resume --jobs 16 --ccache-size 32G
```

不要删除 workspace、out、ccache、checkpoints，也不要把源码或 ROM 压缩到 `/`、
`/home` 或其他系统盘路径。完成后 ROM 在
`/work/lineage-build/workspace/out/target/product/alice/`，先运行脚本自带的
`verify-rom.py` 门禁，再复制产物。
