# CLAUDE.md

Guidance for Claude Code when working on this builder.

## What this is

A GitHub Actions build of **LineageOS 15.1 (Android 8.1)** for **Huawei CAM-TL00
(Honor 5A)**, using the upstream P8 Lite (`alice`) device tree unmodified except
for three values.

Pushed to <https://github.com/baiyunquan/Action-LineageOS-Builder> (public, so
Actions minutes are unlimited). This directory is a git repo; the parent
directory is not, and **must never be committed** — it holds IMEI-bearing
partition dumps. See `../CLAUDE.md` for the device background.

## Design constraints that shaped everything here

1. **The free runner has a hard 6h job cap** and a 4-core LOS 15.1 build does
   not fit in one pass.
2. **Runners are ephemeral.** `out/` and the source tree do *not* survive
   between runs. The workflow's `disable_ccache` input defaults to `true`, so
   the normal run also creates no ccache directory and uses no Actions cache.
   If explicitly disabled, only then does `actions/cache` provide a
   ccache-warm restart; it is still not a true incremental resume.
3. **AOSP 8.1 will not build on a modern host.** ubuntu-22.04's gcc-11/12
   rejects 2017-era C++, and the runner has no python2 or openjdk-8. Hence the
   split: `repo` runs on the **host** (needs new python3), the compiler runs in
   an **ubuntu:18.04 container** (needs old userland).
4. **LineageOS 15.1-era manifests still use `git://`**, which GitHub disabled in
   2022. `sync-source.sh` installs an `insteadOf` rewrite; without it `repo sync`
   fails outright.

## Files

There are two build paths. Sync and patching are **shared**; only the compile
step differs.

| File | Runs where | Purpose |
|---|---|---|
| `.github/workflows/lineage-build.yml` | — | CI, `workflow_dispatch` only |
| `scripts/build-local.sh` | host | local driver: preflight, sync, build, verify |
| `docker/Dockerfile` | — | local builder image; deps installed once |
| `scripts/build-inner.sh` | container/host | local compile step, no timeout logic |
| `scripts/build-in-container.sh` | ubuntu:18.04 | CI compile step, with timeout + resume |
| `scripts/cci-run.sh` | local KooCLI | create, poll, and delete one Huawei CCI2 build Pod |
| `scripts/cci-pod-entrypoint.sh` | CCI2 Pod | clone GitHub, sync, build, and upload OBS state |
| `CCI_RUNBOOK.md` | — | verified Guiyang CCI2/SWR/OBS resources and constraints |
| `scripts/sync-source.sh` | host | shared: pristine repo init/sync |
| `scripts/apply-source-patches.sh` | host | shared: apply all local patches and verify blobs |
| `scripts/apply-device-patches.sh` | host | shared: the 3 BoardConfig.mk edits |
| `scripts/apply-alice-patcher.sh` | host | shared: idempotent replacement for `patches.sh` |
| `scripts/verify-rom.py` | host | shared: output gate, run before anything reaches the phone |
| `local_manifests/alice.xml` | — | 4 repos, all pinned `lineage-15.1` |

Prefer the **local** path when iterating on the device tree: CI re-runs replay
all 92680 targets, whereas locally `out/` persists and a one-line change
rebuilds in minutes. Keep the timeout/resume logic out of `build-inner.sh` — a
local build that stops is a genuine error, not "time ran out, re-run me".

Build product is `lineage_alice-userdebug`; output lands in
`out/target/product/alice/` (PRODUCT_DEVICE is `alice`, not `cam`).

## The only three device-tree changes

`apply-device-patches.sh` rewrites whole lines in
`device/huawei/alice/BoardConfig.mk`, so it is idempotent:

```makefile
TARGET_OTA_ASSERT_DEVICE := hi6210sft,alice,cam,carmel,CAM-TL00,HWCAM-H
BOARD_USERDATAIMAGE_PARTITION_SIZE := 11473518592   # upstream 11605639168 is 126MB too big
WITH_DEXPREOPT := false                              # time + system-image space
```

It also **asserts** that kernel base/pagesize and the system/boot/recovery/cache
sizes still match the phone. If upstream ever changes one, the script fails
rather than producing an unflashable image. Do not weaken those assertions.

## Four build failures already paid for — do not reintroduce them

Each of these cost a CI run. They are fixed in both build paths; if you touch
the environment setup, keep them.

1. **Do not rewrite bionic's apt sources to `old-releases.ubuntu.com`.** 18.04 is
   still under ESM, so bionic is on `archive.ubuntu.com`. Verified directly:
   `old-releases.../dists/bionic/Release` → 404, `archive.../dists/bionic/Release`
   → 200. The rewrite made *every* package unresolvable. The build scripts now
   default to the official archive; `USE_CN_MIRRORS=1` is an explicit opt-in for
   Huawei Cloud → Aliyun when running on a mainland-China network.
2. **Never restore `set -u` after sourcing `envsetup.sh`.** `lunch` dies with
   `TOP: unbound variable`. `-u` stays off for the rest of the script.
3. **`mka` is a shell function, not a binary.** Anything that execs it
   (`timeout`, `docker run`, `xargs`) fails with exit 127. Use
   `make -j N bacon`; `bacon` is a real target in `vendor/lineage/build/tasks`
   and `lunch` exports everything make needs.
4. **Jack cannot start in a container** — it uses a local TLS socket with certs
   generated on first run, and fails at `setup-jack-server` with "SSL error when
   connecting to the Jack server". `ANDROID_COMPILE_WITH_JACK=false` uses
   javac/d8, which is correct for 8.1 anyway (Jack was deprecated in 8.0).

Also unresolved: CI run 4 compiled for ~2h, then `Save ccache` failed and
skipped verification and upload, so **it was never established whether that run
produced a ROM**. The likely cause is the ccache exceeding the 10GB per-repo
cache budget. If you pick this up, check that first, and give the ccache save
step an `if: always()`-style guard so it cannot skip the verify/upload steps.

## Things that will bite you

- **`apply-alice-patcher.sh` must stay idempotent.** Upstream's `patches.sh`
  uses bare `patch -p1` (prompts `Assume -R?` once applied) and a `git
  cherry-pick`; neither survives a re-run. The replacement uses stamp files in
  `.alice_patches_applied/` as the authority. The stamps are **not optional**:
  the `patch --forward` fallback runs with fuzz and was observed re-applying a
  patch at a shifted offset, silently duplicating changes. Reverse-check alone
  does not catch that.
- The upstream cherry-pick (`ffaaece`, "prebuilt: Drop lineage-radio.rc") only
  deletes one file, so it is done directly. **Do not drop this step** — it stops
  radio services being killed under Huawei RIL, and telephony is a
  confirmed-working feature on this phone.
- `repo sync --force-sync` runs against the pristine checkout restored from the
  CI `.repo` cache. Patch application happens *after* sync in
  `apply-source-patches.sh`; keep that order.
- `build-in-container.sh` deliberately uses `set -uo pipefail` **without `-e`**,
  because it needs to inspect `mka`'s exit code. Exit 124 from `timeout` is
  translated to **75** = "ran out of time, re-run me"; the workflow treats 75 as
  not-a-failure so ccache still gets saved. Any other non-zero is a real error.
- `source build/envsetup.sh` is wrapped in `set +u` / `set -u` — it references
  unset variables and would abort otherwise.
- Git LFS must be hydrated inside the build container. The old CI failure left
  `external/chromium-webview/prebuilt/arm64/webview.apk` as a 134-byte LFS
  pointer. The manifest creates separate repositories for each WebView ABI, so
  `build-in-container.sh` pulls those child repositories from their Gerrit LFS
  endpoint, scans for remaining pointers, and verifies the arm64 APK is a real
  ZIP before allowing compilation to start.
- The GitHub runner's root filesystem is intentionally filled by
  `maximize-build-space`; `actions/cache` otherwise stages its archive under
  the nearly-full root volume and fails with `zstd: ... No space left on
  device`. The workflow creates `/work/runner-temp` and passes it as
  `RUNNER_TEMP`/`TMPDIR` to every cache restore/save step.
- ccache defaults to 6G against a **10GB per-repo cache budget**. Raising it can
  evict the entry entirely and make re-runs slower, not faster.

## Verifying before flashing

```bash
python3 scripts/verify-rom.py --product-out out/target/product/alice --zip <rom.zip>
```

Expected values come from the phone's own backup, not from the alice tree. This
was tested both ways: the known-good LineageOS 14.1 `boot.img` passes, and a
boot image with kernel address forced to `0x07487800` correctly fails with
exit 1.
