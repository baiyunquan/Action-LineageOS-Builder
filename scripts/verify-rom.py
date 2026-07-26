#!/usr/bin/env python3
"""
Gate the LineageOS 15.1 build output before it is ever flashed to CAM-TL00.

Every expected value here was measured from this phone's own backup
(device_info/partitions.txt, device_info/by-name.txt, partitions/boot_raw.img),
not copied from the alice device tree. Defaults:

  system.img   <= 2684354560   mmcblk0p38, 2621440 KiB -- exactly full, no slack
  boot.img     <= 25165824     mmcblk0p27, 24576 KiB
  kernel_addr  == 0x07480000   from the stock boot_raw.img header
  ramdisk_addr == 0x0f000000
  tags_addr    == 0x09e00000
  page_size    == 2048

A boot image with the wrong load addresses produces a black screen with no
recovery path other than reflashing the stock backup, so these are hard errors.

Usage:
    verify-rom.py --product-out out/target/product/alice [--zip <rom.zip>]
"""
import argparse
import os
import struct
import sys
import zipfile

HDR_FMT = "<8s10I16s512s32s"
HDR_SIZE = struct.calcsize(HDR_FMT)

# Measured from partitions/boot_raw.img and device_info/partitions.txt.
DEFAULTS = {
    "kernel_addr": 0x07480000,
    "ramdisk_addr": 0x0F000000,
    "tags_addr": 0x09E00000,
    "page_size": 2048,
    "system_max": 2684354560,
    "boot_max": 25165824,
}

errors = []
warnings = []


def fail(msg):
    errors.append(msg)
    print("  FAIL %s" % msg)


def ok(msg):
    print("  ok   %s" % msg)


def warn(msg):
    warnings.append(msg)
    print("  warn %s" % msg)


def read_boot_header(path):
    with open(path, "rb") as fh:
        data = fh.read(HDR_SIZE)
    fields = struct.unpack(HDR_FMT, data)
    if fields[0] != b"ANDROID!":
        raise ValueError("not an Android boot image")
    return {
        "kernel_size": fields[1],
        "kernel_addr": fields[2],
        "ramdisk_size": fields[3],
        "ramdisk_addr": fields[4],
        "second_size": fields[5],
        "second_addr": fields[6],
        "tags_addr": fields[7],
        "page_size": fields[8],
        "dt_size": fields[9],
        "cmdline": fields[12].split(b"\0", 1)[0].decode("ascii", "replace"),
    }


def check_boot(path, args):
    print("\n== boot.img: %s" % path)
    size = os.path.getsize(path)
    if size > args.boot_max:
        fail("boot.img is %d bytes, exceeds mmcblk0p27 (%d)" % (size, args.boot_max))
    else:
        ok("size %d <= %d" % (size, args.boot_max))

    try:
        hdr = read_boot_header(path)
    except ValueError as exc:
        fail("%s: %s" % (path, exc))
        return

    for key in ("kernel_addr", "ramdisk_addr", "tags_addr"):
        want = getattr(args, key)
        if hdr[key] != want:
            fail("%s is 0x%08x, expected 0x%08x" % (key, hdr[key], want))
        else:
            ok("%s = 0x%08x" % (key, hdr[key]))

    if hdr["page_size"] != args.page_size:
        fail("page_size is %d, expected %d" % (hdr["page_size"], args.page_size))
    else:
        ok("page_size = %d" % hdr["page_size"])

    # CAM-TL00 takes its DTB from the dtimage partition (mmcblk0p29), which the
    # ROM never touches. A boot image carrying its own appended DTB would be a
    # sign the device tree started building one, which is not what this phone
    # expects.
    if hdr["dt_size"] != 0:
        warn("dt_size is %d; CAM-TL00 uses the stock dtimage partition, expected 0"
             % hdr["dt_size"])
    else:
        ok("dt_size = 0 (DTB comes from dtimage p29)")

    print("  cmdline: %s" % hdr["cmdline"])


def check_system(path, args):
    print("\n== system.img: %s" % path)
    size = os.path.getsize(path)
    if size > args.system_max:
        fail("system.img is %d bytes, exceeds mmcblk0p38 (%d) -- flashing will fail"
             % (size, args.system_max))
    else:
        pct = 100.0 * size / args.system_max
        ok("size %d <= %d (%.1f%% of partition)" % (size, args.system_max, pct))
        if pct > 95.0:
            warn("system.img is at %.1f%% of the partition -- very little slack" % pct)


def check_zip(path):
    print("\n== ROM zip: %s" % path)
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        script = "META-INF/com/google/android/updater-script"
        if script not in names:
            fail("%s missing from zip" % script)
            return
        text = zf.read(script).decode("utf-8", "replace")

    # The alice-based TWRP reports ro.product.device=hi6210sft; that is how the
    # verified LineageOS 14.1 package passed its assert on this phone.
    if "hi6210sft" in text:
        ok("updater-script asserts hi6210sft")
    else:
        fail("updater-script does not accept hi6210sft -- TWRP will refuse to install")

    for extra in ("CAM-TL00", "HWCAM-H"):
        if extra in text:
            ok("updater-script also accepts %s" % extra)
        else:
            warn("updater-script does not list %s" % extra)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--product-out", default="out/target/product/alice")
    p.add_argument("--zip")
    p.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=DEFAULTS["kernel_addr"])
    p.add_argument("--ramdisk-addr", type=lambda v: int(v, 0), default=DEFAULTS["ramdisk_addr"])
    p.add_argument("--tags-addr", type=lambda v: int(v, 0), default=DEFAULTS["tags_addr"])
    p.add_argument("--page-size", type=int, default=DEFAULTS["page_size"])
    p.add_argument("--system-max", type=int, default=DEFAULTS["system_max"])
    p.add_argument("--boot-max", type=int, default=DEFAULTS["boot_max"])
    args = p.parse_args()

    print("Verifying build output against CAM-TL00 measured geometry")

    boot = os.path.join(args.product_out, "boot.img")
    system = os.path.join(args.product_out, "system.img")

    if os.path.exists(boot):
        check_boot(boot, args)
    else:
        fail("%s not found" % boot)

    if os.path.exists(system):
        check_system(system, args)
    else:
        fail("%s not found" % system)

    if args.zip:
        if os.path.exists(args.zip):
            check_zip(args.zip)
        else:
            fail("%s not found" % args.zip)

    print("\n%s" % ("-" * 60))
    if warnings:
        print("%d warning(s)" % len(warnings))
    if errors:
        print("FAILED: %d problem(s) -- do not flash this build" % len(errors))
        return 1
    print("PASSED: output is consistent with CAM-TL00 partition geometry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
