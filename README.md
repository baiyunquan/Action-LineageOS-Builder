# LineageOS 15.1 for Huawei CAM-TL00 (Honor 5A / 荣耀畅玩5A)

用通用 `hi6210sft` (`alice`) 设备树为 CAM-TL00 构建 LineageOS 15.1（Android 8.1），
支持 GitHub Actions、本地 x86_64，以及华为云 CCI2 三条编译路线。

设备当前停留在 Android 6.0 EMUI（`HONOR/CAM-TL00/HWCAM-H:6.0/.../C01B243`）。
DanteFX 编译的通用 hi6210sft **LineageOS 14.1 已实测可用，WiFi、通话/移动数据、
相机三项均正常** —— 这是本方案的可行性基础。

---

## 当前状态

**尚未产出可刷机的 ROM。** CI 上跑了 4 轮，逐个修掉了真实的构建错误：

| Run | 结果 | 修复 |
|---|---|---|
| 1 | apt 全部包找不到 | `sed` 把源改到 old-releases 是**写反的** —— bionic 在华为云镜像可用，脚本现在优先 `repo.huaweicloud.com/ubuntu`，失败回退阿里云，同时检查 apt 退出码 |
| 2 | `exit 127` | `timeout ... mka` —— `mka` 是 `envsetup.sh` 定义的 shell 函数，无法被 exec。改用 `make -j N bacon` |
| 3 | 编译到 5% (4878/92680) 后失败 | Jack server 在容器内 SSL 握手失败。改用 javac（`ANDROID_COMPILE_WITH_JACK=false`） |
| 4 | 连续编译约 2 小时后，`Save ccache` 步骤失败 | **未确认**：该步失败导致后续校验/上传被跳过，编译本身是否产出 zip 未能查证 |

已确认可用的部分：repo 同步、设备树补丁、`alice_patcher` 补丁、`lunch`
（`TARGET_PRODUCT=lineage_alice`）、以及约 2 小时的实际编译。

未确认的部分：Run 4 是否真的编译完成、`Save ccache` 为何失败（很可能是 ccache
超过仓库 10GB 缓存额度）、以及后续的产物校验与上传路径。

---

## 为什么可以直接用 P8 Lite 的设备树

CAM-TL00 与 P8 Lite (ALE-L21, 代号 `alice`) 不只是「同平台」，而是**同一套硬件配置**。
下面每一项都来自本机备份的实测比对（`device_info/`、`partitions/boot_raw.img`），
不是推断：

| 项目 | alice 设备树声明 | CAM-TL00 实测 | 结论 |
|---|---|---|---|
| SoC | hi6210sft (Kirin 620) | `ro.board.platform=hi6210sft` | 一致 |
| kernel 加载地址 | base `0x07478000` + `0x8000` | `0x07480000` | 相同 |
| ramdisk / tags | `0x0f000000` / `0x09e00000` | `0x0f000000` / `0x09e00000` | 相同 |
| page size | 2048 | 2048 | 相同 |
| system (p38) | `2684354560` | 2621440 KiB = `2684354560` | **精确相等** |
| boot (p27) | `25165824` | 24576 KiB = `25165824` | **精确相等** |
| recovery (p28) | `67108864` | 65536 KiB = `67108864` | **精确相等** |
| cache (p34) | `268435456` | 262144 KiB = `268435456` | **精确相等** |
| userdata (p40) | `11605639168` | 11204608 KiB = `11473518592` | ⚠ 需下调，已处理 |
| fstab 硬编码分区号 | p11,12,13,14,15,17,18,19,27,28,33,34,38,39,40 | 逐一比对 by-name | **15/15 全中** |
| 屏幕 | 720x1280 / density 320 | `hw.lcd.density=320` | 一致 |

`rootdir/fstab.hi6210sft` 用的是**硬编码 `/dev/block/mmcblk0pNN`**（不是 by-name
软链），所以分区号必须逐个核对 —— 结果 15 个全部对得上。

### WiFi：本以为是最大风险，实际不是

CAM-TL00 用的是**海思 hi110x**（`system/bin/hi110x_*`、`wpa_supplicant_hisi.conf`），
不是 P8 Lite BoardConfig 里写的博通 bcm4343。但：

- alice 内核**自带** `drivers/huawei_platform/connectivity/hisi/hisiwifi/hi110x.c`，
  且 `alice_defconfig` 已有 `CONFIG_CONNECTIVITY_HI110X=y`；
- alice 设备树**自带** `wifi/wpa_supplicant_hisi.conf`、`hostapd_hisi.conf`；
- alice vendor **已包含本机固件** `SDIO_RW_CARMEL_TL00H_FEM.bin`
  （CARMEL 是荣耀5A 的华为代号，dtimage 里本机板名正是 `CAM-TL00H`）。

也就是说这套树本来就是按「通用 hi6210sft」做的，同时覆盖 ALE 和 CAM。

### DTB 不由 ROM 提供 —— 所以不需要移植内核设备树

`boot.img` 头部 `dt_size=0`；设备树来自独立的 `dtimage` 分区 (p29)，其中含
**30 个板型 DTB**，同时包含 `CAM-TL00H` 和 ALE/CHC/CHERRY_PLUS，由 bootloader
按板 ID 选择。刷 ROM 不触碰该分区，面板/触摸/摄像头配置始终由原厂 DTB 提供。

这正是通用包能同时跑在 ALE 和 CAM 上的原因，也意味着**零内核 DTS 工作量**。

---

## 需要改的只有三处

`scripts/apply-device-patches.sh` 对上游 `device/huawei/alice` 只做三处改动
（脚本重写整行，可重复执行）：

```makefile
TARGET_OTA_ASSERT_DEVICE := hi6210sft,alice,cam,carmel,CAM-TL00,HWCAM-H
BOARD_USERDATAIMAGE_PARTITION_SIZE := 11473518592   # CAM p40 实测值，上游偏大 126MB
WITH_DEXPREOPT := false                              # 省时间，也省 system 空间
```

脚本同时**断言** kernel 地址、system/boot/recovery/cache 四个分区尺寸没有漂移 ——
这些值一旦被上游改动就会导致刷不进或刷不开机。

---

## 编译

有两条路线，同步与打补丁的脚本完全共用，产出的源码树一致：

| | GitHub Actions | 本地 x86_64 |
|---|---|---|
| 入口 | Actions → Run workflow | [`./scripts/build-local.sh`](scripts/build-local.sh) |
| 单次时长 | **6 小时硬上限** | 无限制 |
| `out/` 保留 | **否**（runner 用完即毁） | 是 |
| 重跑语义 | ccache 预热后从头再来 | **真正的增量编译** |
| 适合 | 只要一个产物 | **反复调设备树** |

本地路线见 **[LOCAL_BUILD.md](LOCAL_BUILD.md)**。若要迭代设备树，强烈建议用本地 ——
CI 上每次重跑都要把 92680 个目标重新走一遍，本地改一行重编通常只要几分钟。

### GitHub Actions

在 GitHub 上新建仓库，把本目录内容推上去，然后手动触发
**Actions → LineageOS 15.1 (CAM-TL00 / hi6210sft) → Run workflow**。

### 关于 6 小时上限（重要）

> ⚠ 补充说明：GitHub runner 是**临时的**，`out/` 与源码树在两次运行之间
> **不会保留**，只有 ccache 经 `actions/cache` 持久化。所以「续跑」实际是
> 「ccache 预热后重新开始」，而不是断点续编 —— 每次运行只是让更多目标文件
> 进入缓存。若始终收敛不了，请改用本地路线。

免费 runner 单任务上限 6 小时，4 核全量编译 LineageOS 15.1 通常 5-10 小时，
**第一次几乎一定跑不完**。因此本工作流设计成**可续跑**：

1. 编译命令外包一层 `timeout 290m`，主动退出而不是被 Actions 强杀 ——
   被强杀会跳过保存 ccache 的步骤，本次进度全部作废；
2. ccache 用 `actions/cache` 持久化，`if: always()` 保证超时也会保存；
3. 超时退出码 75，工作流不判定为失败，只在 Summary 提示「重新运行以继续」；
4. 第 2～3 次运行 ccache 命中率高，通常能在时限内完成。

**用法：触发后如果 Summary 显示 "Build incomplete"，直接再点一次 Run workflow。**

### Huawei Cloud CCI2

云端路线保留 GitHub 作为源码入口，由本地 KooCLI 创建一次性的 CCI2 Pod，
Pod 内执行同一套 `sync-source.sh` 与 `build-in-container.sh`，并把日志、ccache
和通过门禁的 ROM 上传到私有 OBS。贵阳资源、规格和运行步骤见
[`CCI_RUNBOOK.md`](CCI_RUNBOOK.md)；执行器是
[`scripts/cci-run.sh`](scripts/cci-run.sh)。

CCI2 使用标准 `general-computing`（16 vCPU / 32 GiB）和额外 470 GiB 临时盘，
总临时空间约 500 GiB。每次运行结束都会删除 Pod，避免闲置计费。不要把
`credentials.csv` 或临时 OBS 凭证提交到仓库。

### 为什么在 ubuntu:18.04 容器里编译

AOSP 8.1 的**主机端工具**用系统编译器构建。ubuntu-22.04 的 gcc-11/12 会拒绝大量
2017 年的 C++ 写法，而且 runner 上没有 python2 和 openjdk-8。bionic 三样齐全，
不用打一堆上游 backport。所以：源码同步在**宿主机**（repo 需要新 python3），
实际编译在**容器**里（需要旧 userland）。

另：LineageOS 15.1 时期的 manifest 仍有 `git://` 地址，而 GitHub 已于 2022 年
关闭 git 协议，`sync-source.sh` 里做了 `insteadOf` 重写，否则 repo sync 直接失败。

---

## 产物门禁

`scripts/verify-rom.py` 在上传前校验，期望值全部来自本机备份实测：

- `system.img` ≤ `2684354560`（p38 **正好装满，没有余量**，超了必然刷失败）
- `boot.img` ≤ `25165824`，且 header 的 kernel/ramdisk/tags 地址与 page size 必须吻合
- `dt_size` 应为 0（DTB 来自 p29）
- zip 内 updater-script 必须接受 `hi6210sft`

已用本机真实产物验证过：已知可用的 LineageOS 14.1 boot.img **通过**全部检查；
把 kernel 地址改成 `0x07487800`（本仓库 README 记录过的 `0x8000` 默认偏移事故）
后**正确失败**。

---

## 刷机

> 先备份。`partitions/boot_raw.img`、`recovery_raw.img` 已在上级目录，动手前先核对 sha256。

1. 用 **alice 版 TWRP**（`twrp-3.1.0-0-alice.img`，或上级目录
   `out/recovery/twrp-3.1.0-0-alice-fde-format.img`）。
   它的 `default.prop` 上报 `ro.product.device=hi6210sft` —— 这正是当初
   LineageOS 14.1 能通过 OTA 断言装上去的原因。
2. 从 Android 6.0 EMUI 跨到 8.1，**必须 `Wipe → Format Data`**（不是
   `Advanced Wipe → Data`），再格式化 `/system` 和 `/cache`。
3. 刷入 zip，重启。关闭了 dexpreopt，首次开机 10-20 分钟属正常。
4. `/cust` (p39) 保持不动，fstab 里是只读挂载。
5. **不要碰 `oeminfo` (p8)，含 IMEI。**

出问题立即回滚：

```bash
fastboot flash boot     partitions/boot_raw.img
fastboot flash recovery partitions/recovery_raw.img
```

### 开机后按这个顺序回归

14.1 上已知正常的三项优先测，出现回归说明是 8.1 适配问题而非硬件问题：

1. 开机、触摸、背光
2. **WiFi** —— `dmesg | grep hi110x` 看驱动是否加载
3. **通话 / 移动数据** —— 双卡识别、`libbalong-ril` 是否起来
4. **相机** —— 前后摄拍照录像
5. 传感器、蓝牙、SD 卡、音频

---

## 已知风险

1. **6 小时上限**是最大不确定性。已设计成可续跑，预计 2-3 次运行完成。若始终
   收敛不了，最务实的退路是租一台 x86_64 云主机（16核/32GB/500GB）跑一次全量，
   之后增量迭代再回到 Actions。
2. **相机最可能出问题。** CAM-TL00 传感器为 `ov13850 / sonyimx328 / imx219 / hi843s`，
   与 P8 Lite 未必完全相同；虽然 `isp.bin` 与可用的 14.1 包内 md5 完全一致
   (`92f45734...`)，但 8.1 的 camera HAL 路径有变化。若异常，可从上级目录
   `file_backup/system.tar.gz` 提取本机原厂 `etc/camera/` 与
   `lib*/hw/camera.hi6210sft.so` 替换。
3. **TWRP 3.1.0 对 Android 8.1 偏旧**，可能无法解密 8.1 的 `/data`。上级目录
   README 已记录过 FDE 格式化问题。若 recovery 挂不上 `/data`，需要升级到
   TWRP 3.2+，那是一轮独立的 recovery 构建工作，不在本方案内。
4. **ccache 与仓库缓存额度**：GitHub 每仓库缓存总量 10GB，默认 `ccache_size=6G`
   已留出余量；调大可能挤掉旧缓存反而拖慢续跑。

---

## 目录

```
lineage_build/
├── .github/workflows/lineage-build.yml   # CI：可续跑的编译工作流
├── docker/Dockerfile                     # 本地：ubuntu:18.04 构建镜像（依赖只装一次）
├── LOCAL_BUILD.md                        # 本地编译方案与说明
├── local_manifests/alice.xml             # 四个仓库，全部锁定 lineage-15.1
├── scripts/
│   ├── build-local.sh                    # 本地：总驱动（预检→同步→编译→门禁）
│   ├── build-inner.sh                    # 本地：纯编译步骤，无超时续跑逻辑
│   ├── sync-source.sh                    # 共用：repo init/sync + 打补丁
│   ├── apply-device-patches.sh           # 共用：设备树三处改动（幂等）
│   ├── apply-alice-patcher.sh            # 共用：alice_patcher 的幂等替代（见下）
│   ├── build-in-container.sh             # CI：bionic 容器内编译，带超时续跑
│   └── verify-rom.py                     # 产物门禁
└── README.md
```

### 关于 `apply-alice-patcher.sh`

上游 `alice_patcher/patches.sh` **无法重复执行**：它用裸 `patch -p1`（补丁已应用时
会交互式追问 `Assume -R?`），还有一个第三方仓库的 `git cherry-pick`。续跑场景下
这会直接卡死或失败。

替代脚本应用同一批补丁，但每个补丁三重判定：**stamp 文件 → 反向应用检测 →
git apply / patch --forward 回退**。stamp 是必需的 —— `patch` 的模糊匹配可能在
偏移位置**重复应用**同一补丁而不报错，实测确认过这一点。

那个 cherry-pick（`ffaaece`，"prebuilt: Drop lineage-radio.rc"）实际只删一个文件，
脚本直接删该文件，天然幂等，也不必在编译时拉取第三方仓库。这个改动**不能跳过** ——
它关系到 Huawei RIL 下 radio 服务被误停的问题，而通话正是本机已确认可用的功能。
