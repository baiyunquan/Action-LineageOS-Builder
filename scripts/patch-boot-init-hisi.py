#!/usr/bin/env python3
"""Remove the forced ``ro.config.hisi_cdma_supported=false`` init setter.

The CAM device init has a shared property-override call immediately after the
three modem properties.  This patch changes only the branch that enters that
shared call, so ``ro.config.modem_number=2`` and
``ro.config.client_number=2`` remain untouched.  It also leaves the property
name in ``.rodata``; the important change is that the setter is no longer
executed.

The input boot image is provenance checked through the SHA-256 of the
Magisk-preserved ``.backup/init`` ELF.  Unknown init revisions are refused.
"""

import argparse
import gzip
import hashlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.bootimg_alice import (  # noqa: E402
    pack_boot_image,
    parse_cpio_newc,
    read_boot_image,
    write_cpio_newc,
)


INIT_ENTRY = ".backup/init"
PROPERTY = b"ro.config.hisi_cdma_supported\0"

# This is the exact instruction sequence in the current CAM-TL00 boot.  The
# final branch normally lands on the shared property_override call at 0x422f48;
# changing its immediate from 5 to 6 skips that call and resumes at 0x422f4c.
UNPATCHED_SEQUENCE = bytes.fromhex("60080090007c2d91e10315aa05000014")
PATCHED_SEQUENCE = bytes.fromhex("60080090007c2d91e10315aa06000014")

# SHA-256 of the .backup/init entry read from the current boot partition.
PINNED_INIT_SHA256 = "a621c4a398211a817df4f7208aaf51c6e53761189fd1abaff59a6fc8439ea6c4"
PATCHED_INIT_SHA256 = "fa59b898dba767014fc888399fa982fe50f83c38902afdef2cafd6232396884b"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _find_all(data: bytes, needle: bytes):
    start = 0
    while True:
        found = data.find(needle, start)
        if found < 0:
            return
        yield found
        start = found + 1


def patch_init_blob(data: bytes, strict: bool = True):
    """Return ``(patched_data, number_of_changes)`` for one init ELF.

    ``strict=False`` is used by the small unit-test fixture; production boot
    image patching always uses the pinned SHA check.
    """

    current_sha = sha256(data)
    if strict and current_sha not in (PINNED_INIT_SHA256, PATCHED_INIT_SHA256):
        raise ValueError("unexpected init SHA-256 %s" % current_sha)

    if PROPERTY not in data:
        raise ValueError("init does not contain the Hisi CDMA property name")

    unpatched = list(_find_all(data, UNPATCHED_SEQUENCE))
    patched = list(_find_all(data, PATCHED_SEQUENCE))
    if unpatched and patched:
        raise ValueError("init contains a partial Hisi CDMA patch")
    if len(unpatched) > 1 or len(patched) > 1:
        raise ValueError("init contains multiple Hisi CDMA setter sites")
    if not unpatched:
        if len(patched) == 1:
            return data, 0
        raise ValueError("Hisi CDMA setter site not found")

    offset = unpatched[0]
    result = bytearray(data)
    result[offset : offset + len(UNPATCHED_SEQUENCE)] = PATCHED_SEQUENCE
    patched = bytes(result)
    if strict and sha256(patched) != PATCHED_INIT_SHA256:
        raise ValueError(
            "unexpected patched init SHA-256 %s (expected %s)"
            % (sha256(patched), PATCHED_INIT_SHA256)
        )
    return patched, 1


def patch_boot_image(input_path: Path, output_path: Path):
    header, kernel, ramdisk, second, dt = read_boot_image(str(input_path))
    cpio = gzip.decompress(ramdisk)
    entries = parse_cpio_newc(cpio)
    names = {name for _fields, name, _payload in entries}
    if INIT_ENTRY not in names:
        raise ValueError("boot ramdisk does not contain .backup/init")

    init = next(payload for _fields, name, payload in entries if name == INIT_ENTRY)
    if sha256(init) not in (PINNED_INIT_SHA256, PATCHED_INIT_SHA256):
        raise ValueError(
            "unexpected .backup/init SHA-256 %s (expected %s)"
            % (sha256(init), "%s or %s" % (PINNED_INIT_SHA256, PATCHED_INIT_SHA256))
        )
    patched_init, changes = patch_init_blob(init, strict=True)
    if changes == 0:
        # Keep an already patched image byte-for-byte identical.  This avoids
        # rewriting a gzip stream merely to prove idempotence.
        output_path.write_bytes(input_path.read_bytes())
        return changes, sha256(init), sha256(init)

    patched_cpio = write_cpio_newc(entries, {INIT_ENTRY: patched_init})
    patched_ramdisk = gzip.compress(patched_cpio, compresslevel=9, mtime=0)
    image = pack_boot_image(header, kernel, patched_ramdisk, second, dt)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image)
    return changes, sha256(init), sha256(patched_init)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="input Android boot image")
    parser.add_argument("output", type=Path, help="patched Android boot image")
    args = parser.parse_args(argv)
    try:
        changes, before, after = patch_boot_image(args.input, args.output)
    except (OSError, ValueError, EOFError) as exc:
        print("!! boot init patch refused: %s" % exc, file=sys.stderr)
        return 1
    if changes:
        print("patched .backup/init: %s -> %s" % (before, after))
        print("boot image: %s" % args.output)
    else:
        print("already patched: %s" % args.input)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
