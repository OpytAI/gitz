#!/usr/bin/env python3
"""File inventory checker: inventories/packages.yaml vs src/**.

Rules:
- Packages with status in {required, deferred} and phase_rank(phase) <= current
  must have a non-hollow package root: at least one *.zig file **directly** in
  the package directory (not in child subpackages). Nested packages are
  inventoried separately (e.g. src/plumbing vs src/plumbing/hash).
- status must be one of: required, excluded, test_only, deferred (case-sensitive lowercase).
- Unexpected top-level packages under src/ (not listed in inventory zig paths)
  cause failure (drift control). Root scaffolding files (root.zig, BUILD.bazel)
  are allowed.
- excluded / test_only packages do not require zig paths.
- Does not require go-git on disk.

Exit 0 on success, 1 on failure.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from phase_util import phase_due, phase_rank  # noqa: E402
from simple_yaml import YamlError, load_path  # noqa: E402

ALLOWED_SRC_ROOT_FILES = {
    "root.zig",
    "BUILD.bazel",
    "BUILD",
}

# Canonical statuses. deferred is an alias of required (enforced the same way).
VALID_STATUSES = frozenset({"required", "excluded", "test_only", "deferred"})
ENFORCED_STATUSES = frozenset({"required", "deferred"})


def zig_rel_to_full(src_root: str, zig_rel: str) -> str:
    if zig_rel.startswith("src/"):
        rel = zig_rel[len("src/") :]
    elif zig_rel == "src":
        rel = ""
    else:
        rel = zig_rel
    return os.path.join(src_root, rel) if rel else src_root


def package_has_zig(src_root: str, zig_rel: str) -> bool:
    """True if package root has at least one direct *.zig file (non-hollow).

    Package root rule (non-recursive):
    - If zig path is a .zig file → present.
    - If zig path is a directory → present only if that directory itself
      contains one or more *.zig entries (not only in subdirectories).
    - Child packages (e.g. src/plumbing/hash) do not satisfy a parent row
      (src/plumbing); each inventory path needs its own root sources.
    """
    full = zig_rel_to_full(src_root, zig_rel)
    if os.path.isfile(full):
        return full.endswith(".zig")
    if not os.path.isdir(full):
        return False
    try:
        names = os.listdir(full)
    except OSError:
        return False
    for name in names:
        if name.endswith(".zig") and os.path.isfile(os.path.join(full, name)):
            return True
    return False


def collect_top_level_src(src_root: str) -> Set[str]:
    if not os.path.isdir(src_root):
        return set()
    names = set()
    for name in os.listdir(src_root):
        if name in ALLOWED_SRC_ROOT_FILES:
            continue
        if name.startswith("."):
            continue
        full = os.path.join(src_root, name)
        if os.path.isdir(full):
            names.add(name)
        elif name.endswith(".zig") and name not in ALLOWED_SRC_ROOT_FILES:
            names.add(name)
    return names


def inventory_top_level_zig(packages: List[Dict[str, Any]]) -> Set[str]:
    tops: Set[str] = set()
    for pkg in packages:
        zig = pkg.get("zig")
        if not zig:
            continue
        parts = zig.split("/")
        if len(parts) >= 2 and parts[0] == "src":
            tops.add(parts[1])
        elif len(parts) == 1 and parts[0] != "src":
            tops.add(parts[0])
    return tops


def check(
    packages_doc: Dict[str, Any],
    src_root: str,
    current_override: Optional[str] = None,
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    packages = packages_doc.get("packages") or []
    current = current_override or packages_doc.get("current_phase")
    if current is None:
        messages.append("error: current_phase missing from packages.yaml")
        return False, messages, {}

    required_due: List[Dict[str, Any]] = []
    missing: List[Dict[str, Any]] = []
    present: List[Dict[str, Any]] = []
    status_errors = 0

    for pkg in packages:
        status = pkg.get("status", "required")
        if status not in VALID_STATUSES:
            messages.append(
                f"error: invalid status {status!r} for go={pkg.get('go')!r} "
                f"(allowed: {sorted(VALID_STATUSES)})"
            )
            status_errors += 1
            continue
        if status not in ENFORCED_STATUSES:
            continue
        phase = pkg.get("phase")
        if phase is None:
            messages.append(f"error: required package {pkg.get('go')!r} missing phase")
            continue
        if not phase_due(phase, current):
            continue
        zig = pkg.get("zig")
        if not zig:
            messages.append(f"error: required package {pkg.get('go')!r} missing zig path")
            continue
        required_due.append(pkg)
        if package_has_zig(src_root, zig):
            present.append(pkg)
        else:
            missing.append(pkg)

    for pkg in missing:
        full = zig_rel_to_full(src_root, pkg.get("zig") or "")
        reason = "missing or hollow (no *.zig)"
        if os.path.isdir(full):
            reason = "hollow directory (no *.zig files)"
        elif not os.path.exists(full):
            reason = "path missing"
        messages.append(
            f"MISSING required package go={pkg.get('go')!r} zig={pkg.get('zig')!r} "
            f"phase={pkg.get('phase')} (current_phase={current}) reason={reason}"
        )

    inv_tops = inventory_top_level_zig(packages)
    disk_tops = collect_top_level_src(src_root)
    unexpected = sorted(disk_tops - inv_tops)
    for name in unexpected:
        messages.append(
            f"UNEXPECTED top-level package under src/: {name!r} (not in packages.yaml)"
        )

    metrics = {
        "current_phase": current,
        "current_rank": phase_rank(current),
        "packages.total": len(packages),
        "packages.required_due": len(required_due),
        "packages.present": len(present),
        "packages.missing": len(missing),
        "packages.unexpected_top": len(unexpected),
        "packages.status_errors": status_errors,
    }

    ok = (
        len(missing) == 0
        and len(unexpected) == 0
        and status_errors == 0
        and not any(m.startswith("error:") for m in messages)
    )
    if ok:
        messages.append(
            f"file inventory OK: current_phase={current} "
            f"required_due={len(required_due)} present={len(present)} missing=0"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--packages", default=None, help="path to packages.yaml")
    p.add_argument("--src-root", default=None, help="path to src/ directory")
    p.add_argument(
        "--current-phase",
        default=None,
        help="override current_phase from packages.yaml",
    )
    p.add_argument("--self-test", action="store_true", help="run unit self-tests")
    args = p.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1

    if not args.packages or not args.src_root:
        p.error("--packages and --src-root are required unless --self-test")

    try:
        doc = load_path(args.packages)
    except (OSError, YamlError) as e:
        print(f"FAIL: cannot load packages.yaml: {e}", file=sys.stderr)
        return 1

    if not isinstance(doc, dict):
        print("FAIL: packages.yaml root must be a mapping", file=sys.stderr)
        return 1

    ok, messages, metrics = check(doc, args.src_root, args.current_phase)
    for m in messages:
        print(m)
    for k, v in sorted(metrics.items()):
        print(f"metric {k}={v}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    from simple_yaml import load

    doc = load(
        """
pin: v5.19.2
current_phase: g
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
  - go: future
    zig: src/future
    phase: 2
    status: required
  - go: _examples
    status: excluded
  - go: storage/test
    phase: 1
    status: test_only
"""
    )
    with tempfile.TemporaryDirectory() as td:
        # empty src — current g → no required due
        ok, msgs, metrics = check(doc, td)
        assert ok, msgs
        assert metrics["packages.required_due"] == 0

        # force phase 1 → missing (phase-2 not due; excluded/test_only ignored)
        ok, msgs, metrics = check(doc, td, current_override="1")
        assert not ok
        assert metrics["packages.missing"] == 1, metrics
        assert metrics["packages.required_due"] == 1
        assert any("MISSING" in m and "plumbing/hash" in m for m in msgs), msgs

        # empty dir is hollow → still missing
        os.makedirs(os.path.join(td, "plumbing", "hash"))
        ok, msgs, metrics = check(doc, td, current_override="1")
        assert not ok
        assert metrics["packages.missing"] == 1
        assert any("hollow" in m for m in msgs), msgs

        # .zig file present → ok
        with open(os.path.join(td, "plumbing", "hash", "hash.zig"), "w", encoding="utf-8") as f:
            f.write("pub const x = 1;\n")
        ok, msgs, metrics = check(doc, td, current_override="1")
        assert ok, msgs
        assert metrics["packages.present"] == 1
        assert metrics["packages.missing"] == 0

        # Parent package is NOT satisfied by child-only *.zig (non-recursive root rule)
        nested = load(
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: plumbing
    zig: src/plumbing
    phase: 1
    status: required
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
"""
        )
        # only child has sources
        ok, msgs, metrics = check(nested, td, current_override="1")
        assert not ok
        assert metrics["packages.present"] == 1  # hash only
        assert metrics["packages.missing"] == 1  # parent hollow
        assert any("MISSING" in m and "go='plumbing'" in m for m in msgs), msgs
        # parent gets its own root .zig → both present
        with open(os.path.join(td, "plumbing", "root.zig"), "w", encoding="utf-8") as f:
            f.write("pub const root = 1;\n")
        ok, msgs, metrics = check(nested, td, current_override="1")
        assert ok, msgs
        assert metrics["packages.present"] == 2
        assert metrics["packages.missing"] == 0
        os.remove(os.path.join(td, "plumbing", "root.zig"))

        # unexpected top-level
        os.makedirs(os.path.join(td, "sneaky"))
        ok, msgs, metrics = check(doc, td, current_override="1")
        assert not ok
        assert any("UNEXPECTED" in m and "sneaky" in m for m in msgs)

        # invalid status fails
        bad = load(
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: foo
    zig: src/foo
    phase: 1
    status: Required
"""
        )
        ok, msgs, metrics = check(bad, td)
        assert not ok
        assert metrics["packages.status_errors"] == 1
        assert any("invalid status" in m for m in msgs)

        # deferred is enforced like required
        defd = load(
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: bar
    zig: src/bar
    phase: 1
    status: deferred
"""
        )
        ok, msgs, metrics = check(defd, td)
        assert not ok
        assert metrics["packages.missing"] == 1
        assert any("MISSING" in m and "bar" in m for m in msgs)

        # required missing phase / zig
        bad2 = load(
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: no-phase
    status: required
    zig: src/x
  - go: no-zig
    status: required
    phase: 1
"""
        )
        ok, msgs, metrics = check(bad2, td)
        assert not ok
        assert any("missing phase" in m for m in msgs)
        assert any("missing zig path" in m for m in msgs)

    print("check_file_inventory self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
