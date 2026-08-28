#!/usr/bin/env python3
"""Patch the pinned Android 8.1 Balong RIL SIMSLOT paths.

Android/framework uses zero-based ``persist.radio.sim_slot_cfg=0,1`` while
the Balong modem uses one-based ``AT^SIMSLOT=1,2``.  This patch keeps the
framework property unchanged and fixes every dual-SIM command path in the
pinned Android 25 RIL.  Unknown or partially patched binaries are rejected.
"""

import hashlib
import sys
from pathlib import Path


ORIGINAL_SHA256 = "dcbb46ec581013a6f13c36dfa3cdb3c769211168e5614cc0cb7c0f321e01aaf4"
PATCHED_SHA256 = "5dd2fa7b0ca370e28b705a3433136a392260cbd071b4e5d0167edc019c11dba5"
MODEM_SLOT_LITERAL_OFFSET = 0x971DA
MODEM_SLOT_LITERAL = b"1,2\0"

# File offsets in the pinned ELF (the executable LOAD has VirtAddr 0x1a000).
#
# request_local_get_sim_slot_cfg():
#   - normalize the two-value comparison to the modem pair 1,2;
#   - use the existing read-only 1,2 literal for the two-value recovery;
#   - normalize the two fixed three-value recovery strings (0,1,2 and 0,1).
#
# requestSetSimSlotCfg(): its two-value API arguments are already modem
# numbered (the working 14.1 implementation sends them unchanged).  The
# original Android 25 blob incorrectly decremented them before AT^SIMSLOT;
# only its subsequent property writes remain ``sub #1`` and therefore keep
# the framework property zero-based.
PATCH_BYTES = {
    # Two-value sync path, compare modem response with 1,2.
    0x67B2C: (bytes.fromhex("e0530091"), bytes.fromhex("88264029")),
    0x67B30: (bytes.fromhex("e1730091"), bytes.fromhex("1f050071")),
    0x67B34: (bytes.fromhex("bbb8fe97"), bytes.fromhex("2009427a")),
    0x67B38: (bytes.fromhex("40060034"), bytes.fromhex("40060054")),
    # Two-value recovery command: AT^SIMSLOT=1,2.
    0x67B64: (bytes.fromhex("e2730091"), bytes.fromhex("a2b31750")),
    # Three-value recovery commands: use 1,2 rather than zero-based strings.
    0x67B90: (bytes.fromhex("42b00491"), bytes.fromhex("42680791")),
    0x67BE8: (bytes.fromhex("42680491"), bytes.fromhex("42680791")),
    # Two-value SET command: send API's one-based arguments unchanged.
    0x67400: (bytes.fromhex("02050051"), bytes.fromhex("e203082a")),
    0x67404: (bytes.fromhex("23050051"), bytes.fromhex("e303092a")),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"!! RIL sim-slot patch refused: {message}")


def patch(path: Path) -> str:
    data = bytearray(path.read_bytes())
    current_sha = sha256(data)
    if current_sha == ORIGINAL_SHA256:
        pass
    elif PATCHED_SHA256 and current_sha == PATCHED_SHA256:
        for offset, (_old, new) in PATCH_BYTES.items():
            if data[offset : offset + len(new)] != new:
                fail(f"partial patch at file offset 0x{offset:x}")
        print(f"   already patched: {path} ({current_sha})")
        return current_sha
    else:
        fail(f"unexpected input SHA-256 {current_sha}")

    for offset, (old, _new) in PATCH_BYTES.items():
        actual = bytes(data[offset : offset + len(old)])
        if actual != old:
            fail(f"unexpected instruction at file offset 0x{offset:x}: {actual.hex()}")

    literal = data[MODEM_SLOT_LITERAL_OFFSET : MODEM_SLOT_LITERAL_OFFSET + len(MODEM_SLOT_LITERAL)]
    if literal != MODEM_SLOT_LITERAL:
        fail("the pinned modem slot literal is not 1,2")

    for offset, (_old, new) in PATCH_BYTES.items():
        data[offset : offset + len(new)] = new

    path.write_bytes(data)
    result = sha256(data)
    print(f"   patched: {path}")
    print(f"   SHA-256: {result}")
    return result


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} PATH_TO_LIBBALONG_RIL_SO", file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        print(f"!! RIL sim-slot patch refused: file not found: {path}", file=sys.stderr)
        return 1
    patch(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
