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
   between runs — only `ccache`, via `actions/cache`. So a re-run is a
   *ccache-warm restart*, not a true incremental resume. Progress is monotonic
   only in the sense that each run leaves more objects cached. Do not describe
   it as "resuming where it left off" — that is not what happens.
3. **AOSP 8.1 will not build on a modern host.** ubuntu-22.04's gcc-11/12
   rejects 2017-era C++, and the runner has no python2 or openjdk-8. Hence the
   split: `repo` runs on the **host** (needs new python3), the compiler runs in
   an **ubuntu:18.04 container** (needs old userland).
4. **LineageOS 15.1-era manifests still use `git://`**, which GitHub disabled in
   2022. `sync-source.sh` installs an `insteadOf` rewrite; without it `repo sync`
   fails outright.

## Files

| File | Runs where | Purpose |
|---|---|---|
| `.github/workflows/lineage-build.yml` | — | `workflow_dispatch` only |
| `scripts/sync-source.sh` | host | repo init/sync, then calls both patch scripts |
| `scripts/apply-device-patches.sh` | host | the 3 BoardConfig.mk edits |
| `scripts/apply-alice-patcher.sh` | host | idempotent replacement for upstream `patches.sh` |
| `scripts/build-in-container.sh` | ubuntu:18.04 | deps, envsetup, lunch, `mka bacon` |
| `scripts/verify-rom.py` | host | output gate; run before anything reaches the phone |
| `local_manifests/alice.xml` | — | 4 repos, all pinned `lineage-15.1` |

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
- `repo sync --force-sync` on a second run runs over a tree that already has
  local modifications. Patch application happens *after* sync in
  `sync-source.sh`; keep that order.
- `build-in-container.sh` deliberately uses `set -uo pipefail` **without `-e`**,
  because it needs to inspect `mka`'s exit code. Exit 124 from `timeout` is
  translated to **75** = "ran out of time, re-run me"; the workflow treats 75 as
  not-a-failure so ccache still gets saved. Any other non-zero is a real error.
- `source build/envsetup.sh` is wrapped in `set +u` / `set -u` — it references
  unset variables and would abort otherwise.
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
