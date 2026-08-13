#!/usr/bin/env python3
"""Check the required package inventory against src/**.

Every required or deferred package must contain a direct Zig source file.
Nested package sources do not satisfy a parent package. Unexpected top-level
source packages fail the check.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

from simple_yaml import YamlError, load, load_path

ALLOWED_SRC_ROOT_FILES = {
    "root.zig",
    "ownership_gpa_test.zig",
    "BUILD.bazel",
    "BUILD",
}
VALID_STATUSES = frozenset({"required", "excluded", "test_only", "deferred"})
ENFORCED_STATUSES = frozenset({"required", "deferred"})


def zig_rel_to_full(src_root: str, zig_rel: str) -> str:
    if zig_rel == "src":
        relative = ""
    elif zig_rel.startswith("src/"):
        relative = zig_rel[len("src/") :]
    else:
        raise ValueError("zig path must be src or start with src/")
    root = os.path.realpath(src_root)
    full = os.path.realpath(os.path.join(root, relative))
    if os.path.commonpath((root, full)) != root:
        raise ValueError("zig path escapes src root")
    return full


def package_has_zig(src_root: str, zig_rel: str) -> bool:
    """Return whether a package root contains a direct Zig source file."""
    try:
        full = zig_rel_to_full(src_root, zig_rel)
    except ValueError:
        return False
    if os.path.isfile(full):
        return full.endswith(".zig")
    if not os.path.isdir(full):
        return False
    try:
        names = os.listdir(full)
    except OSError:
        return False
    return any(
        name.endswith(".zig") and os.path.isfile(os.path.join(full, name))
        for name in names
    )


def collect_top_level_src(src_root: str) -> Set[str]:
    if not os.path.isdir(src_root):
        return set()
    names: Set[str] = set()
    for name in os.listdir(src_root):
        if name in ALLOWED_SRC_ROOT_FILES or name.startswith("."):
            continue
        full = os.path.join(src_root, name)
        if os.path.isdir(full) or name.endswith(".zig"):
            names.add(name)
    return names


def inventory_top_level_zig(packages: List[Dict[str, Any]]) -> Set[str]:
    tops: Set[str] = set()
    for package in packages:
        zig = package.get("zig")
        if not isinstance(zig, str) or not zig:
            continue
        parts = zig.split("/")
        if len(parts) >= 2 and parts[0] == "src":
            tops.add(parts[1])
        elif parts[0] != "src":
            tops.add(parts[0])
    return tops


def check(
    packages_doc: Dict[str, Any], src_root: str
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    packages = packages_doc.get("packages") or []
    if not isinstance(packages, list):
        return False, ["error: packages must be a list"], {}

    required: List[Dict[str, Any]] = []
    missing: List[Dict[str, Any]] = []
    status_errors = 0
    for package in packages:
        if not isinstance(package, dict):
            messages.append(f"error: package entry must be a mapping: {package!r}")
            status_errors += 1
            continue
        status = package.get("status", "required")
        if status not in VALID_STATUSES:
            messages.append(
                f"error: invalid status {status!r} for go={package.get('go')!r} "
                f"(allowed: {sorted(VALID_STATUSES)})"
            )
            status_errors += 1
            continue
        if status not in ENFORCED_STATUSES:
            continue
        zig = package.get("zig")
        if not isinstance(zig, str) or not zig:
            messages.append(
                f"error: required package {package.get('go')!r} missing zig path"
            )
            status_errors += 1
            continue
        try:
            zig_rel_to_full(src_root, zig)
        except ValueError as error:
            messages.append(
                f"error: invalid zig path for {package.get('go')!r}: {error}"
            )
            status_errors += 1
            continue
        required.append(package)
        if not package_has_zig(src_root, zig):
            missing.append(package)

    for package in missing:
        zig = package["zig"]
        full = zig_rel_to_full(src_root, zig)
        reason = "missing or hollow (no *.zig)"
        if os.path.isdir(full):
            reason = "hollow directory (no *.zig files)"
        elif not os.path.exists(full):
            reason = "path missing"
        messages.append(
            f"MISSING required package go={package.get('go')!r} "
            f"zig={zig!r} reason={reason}"
        )

    unexpected = sorted(
        collect_top_level_src(src_root) - inventory_top_level_zig(packages)
    )
    for name in unexpected:
        messages.append(
            f"UNEXPECTED top-level package under src/: {name!r} "
            "(not in packages.yaml)"
        )

    metrics = {
        "packages.total": len(packages),
        "packages.required": len(required),
        "packages.present": len(required) - len(missing),
        "packages.missing": len(missing),
        "packages.unexpected_top": len(unexpected),
        "packages.status_errors": status_errors,
    }
    ok = not missing and not unexpected and status_errors == 0
    if ok:
        messages.append(
            f"file inventory OK: required={len(required)} present={len(required)} "
            "missing=0"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages")
    parser.add_argument("--src-root")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return 0 if _self_test() else 1
    if not args.packages or not args.src_root:
        parser.error("--packages and --src-root are required unless --self-test")
    try:
        doc = load_path(args.packages)
    except (OSError, YamlError) as error:
        print(f"FAIL: cannot load packages.yaml: {error}", file=sys.stderr)
        return 1
    if not isinstance(doc, dict):
        print("FAIL: packages.yaml root must be a mapping", file=sys.stderr)
        return 1
    ok, messages, metrics = check(doc, args.src_root)
    for message in messages:
        print(message)
    for key, value in sorted(metrics.items()):
        print(f"metric {key}={value}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    doc = load(
        """
pin: v5.19.2
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    status: required
  - go: ignored/test
    status: test_only
"""
    )
    with tempfile.TemporaryDirectory() as temp_dir:
        ok, messages, metrics = check(doc, temp_dir)
        assert not ok, messages
        assert metrics["packages.missing"] == 1

        package_dir = os.path.join(temp_dir, "plumbing", "hash")
        os.makedirs(os.path.join(package_dir, "nested"))
        with open(os.path.join(package_dir, "nested", "child.zig"), "w") as file:
            file.write("pub fn child() void {}\n")
        ok, messages, _ = check(doc, temp_dir)
        assert not ok, messages

        with open(os.path.join(package_dir, "root.zig"), "w") as file:
            file.write("pub fn new() void {}\n")
        ok, messages, metrics = check(doc, temp_dir)
        assert ok, messages
        assert metrics["packages.present"] == 1

        os.makedirs(os.path.join(temp_dir, "unexpected"))
        ok, messages, _ = check(doc, temp_dir)
        assert not ok
        assert any("UNEXPECTED" in message for message in messages)

    invalid = load("packages:\n  - go: broken\n    status: unknown\n")
    ok, messages, _ = check(invalid, "/nonexistent")
    assert not ok
    assert any("invalid status" in message for message in messages)

    unsafe = load(
        "packages:\n  - go: broken\n    zig: ../outside\n    status: required\n"
    )
    ok, messages, _ = check(unsafe, "/tmp/src")
    assert not ok
    assert any("invalid zig path" in message for message in messages)
    print("check_file_inventory self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
