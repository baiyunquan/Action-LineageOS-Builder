#!/usr/bin/env python3
"""Bind each Android 8.1 Huawei rild process to one HIDL radio slot.

The pinned Huawei ``rild`` hard-codes ``slot1`` even for ``-c 1`` and its
``libril.so`` registers the complete seven-entry Huawei service list from
each process.  The result is that modem1 registers after modem0 and owns
both framework slots.  This narrowly scoped patch restores the AOSP multi-
rild contract: client 0 -> slot1 and client 1 -> slot2, with one dynamic
slot registered by each process.

Only the exact pinned ARM64 binaries are accepted.  The patch is idempotent
and refuses partial or unknown binaries.
"""

import hashlib
import struct
import sys
from pathlib import Path


ORIGINAL_RILD_SHA256 = "1e21f92173c41a115596093def18930f849bbc0995a8a5072af9b6ee5aa428a2"
PATCHED_RILD_SHA256 = "7593482cf739e5bbcac182e02acdfc422577e0b7aa15cd1dbf69a66b75d8a88b"
ORIGINAL_LIBRIL_SHA256 = "f800fca01183596daff487cbc19475f1fdff95c7c8bbdc879bf52ed6da724386"
PATCHED_LIBRIL_SHA256 = "58f323ee6b0a24d0cc3c75da77b6ff2d99fa6a3fc88884f73d4d5f49ad3094b9"

RILD_SLOT2_OFFSET = 0x39A2
RILD_ENTRY_OFFSET = 0x32EC
RILD_ALT_ENTRY_OFFSET = 0x3118
RILD_CAVE_OFFSET = 0x3C4C
RILD_CAVE_SIZE = 0x28
RILD_ALT_CAVE_OFFSET = 0x3C74
RILD_ALT_CAVE_SIZE = 0x30

LIBRIL_ENTRY_OFFSET = 0x67440
LIBRIL_LOOP_EXIT_OFFSET = 0x67750
LIBRIL_CAVE_OFFSET = 0xAE724
LIBRIL_CAVE_SIZE = 0x14


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def insn(value: int) -> bytes:
    return struct.pack("<I", value)


def branch(pc: int, target: int) -> bytes:
    delta = target - pc
    if delta % 4:
        raise ValueError("branch target is not instruction-aligned")
    imm = delta // 4
    if not -(1 << 25) <= imm < (1 << 25):
        raise ValueError("branch target is outside AArch64 B range")
    return insn(0x14000000 | (imm & 0x03FFFFFF))


def branch_link(pc: int, target: int) -> bytes:
    delta = target - pc
    if delta % 4:
        raise ValueError("branch target is not instruction-aligned")
    imm = delta // 4
    if not -(1 << 25) <= imm < (1 << 25):
        raise ValueError("branch target is outside AArch64 BL range")
    return insn(0x94000000 | (imm & 0x03FFFFFF))


def branch_cond(pc: int, target: int, condition: int) -> bytes:
    delta = target - pc
    if delta % 4:
        raise ValueError("conditional branch target is not aligned")
    imm = delta // 4
    if not -(1 << 18) <= imm < (1 << 18):
        raise ValueError("conditional branch target is outside range")
    return insn(0x54000000 | ((imm & 0x7FFFF) << 5) | (condition & 0xF))


def fail(message: str) -> None:
    raise SystemExit(f"!! HIDL RIL registration patch refused: {message}")


def patch_rild(path: Path) -> str:
    data = bytearray(path.read_bytes())
    current = sha256(data)
    if PATCHED_RILD_SHA256 and current == PATCHED_RILD_SHA256:
        if data[RILD_SLOT2_OFFSET : RILD_SLOT2_OFFSET + 6] != b"slot2\0":
            fail(f"patched rild has an invalid slot2 literal: {path}")
        if data[RILD_ALT_ENTRY_OFFSET : RILD_ALT_ENTRY_OFFSET + 4] != branch(
            RILD_ALT_ENTRY_OFFSET, RILD_ALT_CAVE_OFFSET
        ):
            fail(f"patched rild has an invalid alternate entry branch: {path}")
        print(f"   already patched: {path} ({current})")
        return current
    if current != ORIGINAL_RILD_SHA256:
        fail(f"unexpected rild SHA-256 {current} for {path}")

    if data[RILD_SLOT2_OFFSET : RILD_SLOT2_OFFSET + 6] != b"    \0 ":
        fail("rild slot2 literal area is not the pinned padding")
    if bytes(data[RILD_ENTRY_OFFSET : RILD_ENTRY_OFFSET + 12]) != bytes.fromhex(
        "0000009000702691a9f9ff97"
    ):
        fail("rild service-name call site changed")
    if bytes(data[RILD_ALT_ENTRY_OFFSET : RILD_ALT_ENTRY_OFFSET + 4]) != bytes.fromhex("79000014"):
        fail("rild alternate service-name path changed")
    if any(data[RILD_CAVE_OFFSET : RILD_CAVE_OFFSET + RILD_CAVE_SIZE]):
        fail("rild code cave is not empty")
    if any(data[RILD_ALT_CAVE_OFFSET : RILD_ALT_CAVE_OFFSET + RILD_ALT_CAVE_SIZE]):
        fail("rild alternate code cave is not empty")

    # The daemon parses ``-c N`` into a stable global client-id string at
    # virtual address 0x60e0.  By the time this call is reached x19 is reused
    # by the Huawei startup code, so reading argv[1] here is not reliable.
    # Select slot2 only when that parsed string is exactly "1"; the normal
    # daemon's value is "0".
    data[RILD_SLOT2_OFFSET : RILD_SLOT2_OFFSET + 6] = b"slot2\0"
    data[RILD_ENTRY_OFFSET : RILD_ENTRY_OFFSET + 12] = b"".join(
        [branch(RILD_ENTRY_OFFSET, RILD_CAVE_OFFSET), insn(0xD503201F), insn(0xD503201F)]
    )
    data[RILD_ALT_ENTRY_OFFSET : RILD_ALT_ENTRY_OFFSET + 4] = branch(
        RILD_ALT_ENTRY_OFFSET, RILD_ALT_CAVE_OFFSET
    )
    cave = b"".join(
        [
            insn(0x90000000),  # adrp x0, 0x3000
            insn(0x91267000),  # add x0, x0, #0x99c (slot1)
            insn(0xF0000001),  # adrp x1, 0x6000
            insn(0x91038021),  # add x1, x1, #0xe0 (parsed client id)
            insn(0x39400021),  # ldrb w1, [x1]
            insn(0x7100C43F),  # cmp w1, #'1'
            branch_cond(RILD_CAVE_OFFSET + 0x18, RILD_CAVE_OFFSET + 0x20, 0x1),
            insn(0x91001800),  # add x0, x0, #6 (slot2)
            branch_link(RILD_CAVE_OFFSET + 0x20, 0x1998),  # RIL_setServiceName
            branch(RILD_CAVE_OFFSET + 0x24, 0x32FC),  # continue with RIL_register
        ]
    )
    data[RILD_CAVE_OFFSET : RILD_CAVE_OFFSET + len(cave)] = cave
    alt_cave = b"".join(
        [
            insn(0xAA0003FB),  # mov x27, x0 (preserve RIL_Init result)
            insn(0x90000000),  # adrp x0, 0x3000
            insn(0x91267000),  # add x0, x0, #0x99c (slot1)
            insn(0xF0000001),  # adrp x1, 0x6000
            insn(0x91038021),  # add x1, x1, #0xe0 (parsed client id)
            insn(0x39400021),  # ldrb w1, [x1]
            insn(0x7100C43F),  # cmp w1, #'1'
            branch_cond(RILD_ALT_CAVE_OFFSET + 0x1C, RILD_ALT_CAVE_OFFSET + 0x24, 0x1),
            insn(0x91001800),  # add x0, x0, #6 (slot2)
            branch_link(RILD_ALT_CAVE_OFFSET + 0x24, 0x1998),  # RIL_setServiceName
            insn(0xAA1B03E0),  # mov x0, x27 (restore RIL_Init result)
            branch(RILD_ALT_CAVE_OFFSET + 0x2C, 0x32FC),
        ]
    )
    data[RILD_ALT_CAVE_OFFSET : RILD_ALT_CAVE_OFFSET + len(alt_cave)] = alt_cave
    result = sha256(data)
    path.write_bytes(data)
    print(f"   patched rild: {path} ({result})")
    return result


def patch_libril(path: Path) -> str:
    data = bytearray(path.read_bytes())
    current = sha256(data)
    if PATCHED_LIBRIL_SHA256 and current == PATCHED_LIBRIL_SHA256:
        if data[LIBRIL_LOOP_EXIT_OFFSET : LIBRIL_LOOP_EXIT_OFFSET + 4] != insn(0x14000001):
            fail(f"patched libril has an invalid loop exit: {path}")
        print(f"   already patched: {path} ({current})")
        return current
    if current != ORIGINAL_LIBRIL_SHA256:
        fail(f"unexpected libril SHA-256 {current} for {path}")

    if bytes(data[LIBRIL_ENTRY_OFFSET : LIBRIL_ENTRY_OFFSET + 8]) != bytes.fromhex(
        "f3031faaf4031faa"
    ):
        fail("libril registration-loop entry changed")
    if bytes(data[LIBRIL_LOOP_EXIT_OFFSET : LIBRIL_LOOP_EXIT_OFFSET + 4]) != bytes.fromhex(
        "2be8ff54"
    ):
        fail("libril seven-service loop exit changed")
    if any(data[LIBRIL_CAVE_OFFSET : LIBRIL_CAVE_OFFSET + LIBRIL_CAVE_SIZE]):
        fail("libril code cave is not empty")

    # Select index 0/1 from the dynamic service name returned by rild, and
    # make the post-iteration branch leave the loop.  The existing loop body
    # then registers exactly one IRadio and one OemHook instance.
    data[LIBRIL_ENTRY_OFFSET : LIBRIL_ENTRY_OFFSET + 8] = b"".join(
        [branch(LIBRIL_ENTRY_OFFSET, LIBRIL_CAVE_OFFSET), insn(0xD503201F)]
    )
    data[LIBRIL_LOOP_EXIT_OFFSET : LIBRIL_LOOP_EXIT_OFFSET + 4] = insn(0x14000001)
    cave = b"".join(
        [
            insn(0xF9401BE0),  # ldr x0, [sp, #0x30] (RIL_getServiceName)
            insn(0x39401014),  # ldrb w20, [x0, #4] ('1' or '2')
            insn(0x5100C694),  # sub w20, w20, #'1'
            insn(0xD37DF293),  # lsl x19, x20, #3
            # File offsets are used consistently here; the ELF load segment
            # adds the same 0xb000 base to both source and target at runtime.
            branch(LIBRIL_CAVE_OFFSET + 0x10, LIBRIL_ENTRY_OFFSET + 0x8),
        ]
    )
    data[LIBRIL_CAVE_OFFSET : LIBRIL_CAVE_OFFSET + len(cave)] = cave
    result = sha256(data)
    path.write_bytes(data)
    print(f"   patched libril: {path} ({result})")
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} RILD_PATH LIBRIL_PATH", file=sys.stderr)
        return 2
    patch_rild(Path(argv[1]))
    patch_libril(Path(argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
