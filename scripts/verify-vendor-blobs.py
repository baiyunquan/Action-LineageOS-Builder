#!/usr/bin/env python3
"""Verify that the selected Android 8.1 vendor blobs survive into system.img.

The alice vendor makefile copies ``vendor/huawei/alice/proprietary`` into the
system image.  That makes it very easy for an old stock extraction to win a
filename collision without the build failing.  This gate checks the source
tree before compilation and the files extracted from the finished ext4 image.
"""

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(SCRIPT_DIR, "vendor-blob-manifest.tsv")


def load_manifest(path):
    entries = []
    with open(path, "r") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 3:
                raise ValueError("%s:%d: expected source, image, sha256" %
                                 (path, lineno))
            source, image, digest = fields
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ValueError("%s:%d: invalid sha256 %r" % (path, lineno, digest))
            entries.append((source, image, digest))
    if not entries:
        raise ValueError("%s: manifest is empty" % path)
    return entries


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def check_file(label, path, expected):
    if not os.path.isfile(path):
        print("  FAIL %s: missing %s" % (label, path))
        return False
    actual = sha256_file(path)
    if actual != expected:
        print("  FAIL %s: %s (expected %s, got %s)" %
              (label, path, expected, actual))
        return False
    print("  ok   %s: %s" % (label, path))
    return True


def check_source(source_root, entries):
    print("\n== vendor source provenance: %s" % source_root)
    tree_vendor_root = os.path.join(source_root, "vendor", "huawei", "alice", "proprietary")
    standalone_vendor_root = os.path.join(source_root, "proprietary")
    # The normal invocation receives the complete Android tree.  Accepting a
    # standalone vendor checkout as well makes the manifest independently
    # auditable against the pinned reference checkout.
    vendor_root = (tree_vendor_root if os.path.isdir(tree_vendor_root)
                   else standalone_vendor_root)
    ok = True
    for source, _image, expected in entries:
        ok = check_file("source", os.path.join(vendor_root, source), expected) and ok
    return ok


def dump_from_image(image, image_path, destination):
    # debugfs takes paths without a leading ./ and understands ext4 images
    # without requiring a privileged mount.  The destination is created by us,
    # so a malformed image cannot overwrite a project file.
    command = ["debugfs", "-R",
               "dump /%s %s" % (image_path.lstrip("/"), destination), image]
    result = subprocess.run(command, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True)
    if result.returncode != 0 or not os.path.isfile(destination):
        detail = (result.stderr or result.stdout).strip().replace("\n", "; ")
        raise RuntimeError("debugfs could not extract /%s: %s" % (image_path, detail))


def check_image(image, entries):
    print("\n== final system.img vendor provenance: %s" % image)
    if not os.path.isfile(image):
        print("  FAIL system image missing: %s" % image)
        return False
    if not shutil_which("debugfs"):
        print("  FAIL debugfs is required to inspect system.img")
        return False

    ok = True
    with tempfile.TemporaryDirectory(prefix="vendor-hash-") as temp_dir:
        for index, (_source, image_path, expected) in enumerate(entries):
            destination = os.path.join(temp_dir, "blob-%d" % index)
            try:
                dump_from_image(image, image_path, destination)
            except (OSError, RuntimeError) as exc:
                print("  FAIL image /%s: %s" % (image_path, exc))
                ok = False
                continue
            ok = check_file("image", destination, expected) and ok
    return ok


def shutil_which(program):
    """Small Python 2.7-compatible replacement for shutil.which."""
    path = os.environ.get("PATH", os.defpath)
    for directory in path.split(os.path.pathsep):
        candidate = os.path.join(directory, program)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    parser.add_argument("--source-root")
    parser.add_argument("--system-image")
    args = parser.parse_args()
    if not args.source_root and not args.system_image:
        parser.error("at least one of --source-root or --system-image is required")

    try:
        entries = load_manifest(args.manifest)
    except (IOError, OSError, ValueError) as exc:
        print("FAIL: %s" % exc, file=sys.stderr)
        return 2

    passed = True
    if args.source_root:
        passed = check_source(os.path.abspath(args.source_root), entries) and passed
    if args.system_image:
        passed = check_image(os.path.abspath(args.system_image), entries) and passed

    if passed:
        print("\nPASSED: vendor source and final image hashes match the pinned manifest")
        return 0
    print("\nFAILED: vendor blob provenance/hash check", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
