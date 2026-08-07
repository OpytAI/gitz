#!/usr/bin/env python3
"""API inventory checker: inventories/api/*.yaml schema + optional symbol presence.

While current_phase is g (or package phase > current), only schema validation
runs for seed files. When a package is due (phase <= current) AND its zig path
exists, semantic IDs must match tokens found in .zig sources (best-effort
substring on the last path component — see docs/GATES.md).

Also: every due required/deferred package in packages.yaml must have a matching
API inventory file (package: field), unless allowlisted later.

Does not require host go or network.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from phase_util import phase_due  # noqa: E402
from simple_yaml import YamlError, load_path  # noqa: E402

ENFORCED_STATUSES = frozenset({"required", "deferred"})


def list_api_files(api_dir: str) -> List[str]:
    if not os.path.isdir(api_dir):
        return []
    out = []
    for name in sorted(os.listdir(api_dir)):
        if name.endswith((".yaml", ".yml")):
            out.append(os.path.join(api_dir, name))
    return out


def validate_schema(doc: Dict[str, Any], path: str) -> List[str]:
    errs: List[str] = []
    if "package" not in doc:
        errs.append(f"{path}: missing package")
    if "phase" not in doc:
        errs.append(f"{path}: missing phase")
    req = doc.get("require")
    if req is None:
        errs.append(f"{path}: missing require")
    elif not isinstance(req, dict):
        errs.append(f"{path}: require must be a mapping")
    else:
        for key in ("types", "functions", "constants"):
            if key in req and req[key] is not None and not isinstance(req[key], list):
                errs.append(f"{path}: require.{key} must be a list")
        if "semantic" in req and req["semantic"] is not None and not isinstance(
            req["semantic"], list
        ):
            errs.append(f"{path}: require.semantic must be a list")
    if "zig_map" in doc and doc["zig_map"] is not None and not isinstance(doc["zig_map"], dict):
        errs.append(f"{path}: zig_map must be a mapping")
    return errs


def load_packages_index(packages_doc: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    idx = {}
    for pkg in packages_doc.get("packages") or []:
        go = pkg.get("go")
        if go:
            idx[go] = pkg
    return idx


def zig_package_present(src_root: str, zig_rel: Optional[str]) -> bool:
    """Non-recursive: package root needs a direct *.zig (not only in child dirs)."""
    if not zig_rel:
        return False
    if zig_rel.startswith("src/"):
        rel = zig_rel[len("src/") :]
    else:
        rel = zig_rel
    full = os.path.join(src_root, rel) if rel else src_root
    if os.path.isfile(full) and full.endswith(".zig"):
        return True
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


def read_zig_blob(src_root: str, zig_rel: str) -> str:
    """Read *.zig files at the package root only (not child packages)."""
    if zig_rel.startswith("src/"):
        rel = zig_rel[len("src/") :]
    else:
        rel = zig_rel
    full = os.path.join(src_root, rel)
    chunks: List[str] = []
    if os.path.isfile(full) and full.endswith(".zig"):
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            chunks.append(f.read())
        return "\n".join(chunks)
    if os.path.isdir(full):
        try:
            names = sorted(os.listdir(full))
        except OSError:
            return ""
        for fn in names:
            if fn.endswith(".zig"):
                p = os.path.join(full, fn)
                if os.path.isfile(p):
                    with open(p, "r", encoding="utf-8", errors="replace") as f:
                        chunks.append(f.read())
    return "\n".join(chunks)


def semantic_ids(doc: Dict[str, Any]) -> List[str]:
    req = doc.get("require") or {}
    ids = list(req.get("semantic") or [])
    zmap = doc.get("zig_map") or {}
    for v in zmap.values():
        if isinstance(v, str) and v not in ids:
            ids.append(v)
    return ids


def check_mapped_presence(doc: Dict[str, Any], zig_text: str) -> List[str]:
    """Best-effort: last path component of zig_map / semantic should appear in sources."""
    missing = []
    for sid in semantic_ids(doc):
        token = sid.split(".")[-1]
        if token and token not in zig_text:
            missing.append(sid)
    return missing


def check(
    packages_doc: Dict[str, Any],
    api_dir: str,
    src_root: str,
    current_override: Optional[str] = None,
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    current = current_override or packages_doc.get("current_phase")
    if current is None:
        return False, ["error: current_phase missing"], {}

    pkg_index = load_packages_index(packages_doc)
    api_files = list_api_files(api_dir)
    schema_errors = 0
    due_packages = 0
    mapped_ok = 0
    mapped_fail = 0
    required_ids = 0
    mapped_ids = 0
    api_packages: Set[str] = set()

    for path in api_files:
        try:
            doc = load_path(path)
        except (OSError, YamlError) as e:
            messages.append(f"error: cannot load {path}: {e}")
            schema_errors += 1
            continue
        if not isinstance(doc, dict):
            messages.append(f"error: {path} root must be a mapping")
            schema_errors += 1
            continue
        errs = validate_schema(doc, path)
        for e in errs:
            messages.append(f"error: {e}")
        schema_errors += len(errs)

        pkg_name = doc.get("package")
        if isinstance(pkg_name, str):
            api_packages.add(pkg_name)
        phase = doc.get("phase")
        ids = semantic_ids(doc)
        required_ids += len(ids)
        zmap = doc.get("zig_map") or {}
        req = doc.get("require") or {}
        names = []
        for key in ("types", "functions", "constants"):
            names.extend(req.get(key) or [])
        for n in names:
            if n in zmap:
                mapped_ids += 1

        if phase is None or not phase_due(phase, current):
            continue

        due_packages += 1
        inv = pkg_index.get(pkg_name) or {}
        zig = inv.get("zig")
        if not zig_package_present(src_root, zig):
            messages.append(
                f"API DUE but zig package missing: package={pkg_name!r} zig={zig!r} "
                f"phase={phase} current_phase={current}"
            )
            mapped_fail += 1
            continue

        zig_text = read_zig_blob(src_root, zig)
        if not zig_text.strip():
            messages.append(f"API DUE hollow package (no zig content): {pkg_name!r}")
            mapped_fail += 1
            continue

        miss = check_mapped_presence(doc, zig_text)
        if miss:
            for sid in miss:
                messages.append(
                    f"API symbol not found in zig sources: {pkg_name} id={sid}"
                )
            mapped_fail += 1
        else:
            mapped_ok += 1

    # Due required packages must have an API inventory seed.
    missing_api = 0
    for go, pkg in pkg_index.items():
        status = pkg.get("status", "required")
        if status not in ENFORCED_STATUSES:
            continue
        phase = pkg.get("phase")
        if phase is None or not phase_due(phase, current):
            continue
        if go not in api_packages:
            messages.append(
                f"API inventory missing for due required package go={go!r} "
                f"phase={phase} current_phase={current}"
            )
            missing_api += 1

    metrics = {
        "current_phase": current,
        "api.files": len(api_files),
        "api.schema_errors": schema_errors,
        "api.due_packages": due_packages,
        "api.mapped_ok": mapped_ok,
        "api.mapped_fail": mapped_fail,
        "api.required_ids": required_ids,
        "api.mapped_ids": mapped_ids,
        "api.missing_for_due": missing_api,
    }

    ok = schema_errors == 0 and mapped_fail == 0 and missing_api == 0
    if ok:
        messages.append(
            f"api inventory OK: files={len(api_files)} due={due_packages} "
            f"schema_errors=0 current_phase={current}"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--packages", default=None)
    p.add_argument("--api-dir", default=None)
    p.add_argument("--src-root", default=None)
    p.add_argument("--current-phase", default=None)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1

    if not args.packages or not args.api_dir or not args.src_root:
        p.error("--packages, --api-dir, and --src-root are required unless --self-test")

    try:
        packages_doc = load_path(args.packages)
    except (OSError, YamlError) as e:
        print(f"FAIL: packages.yaml: {e}", file=sys.stderr)
        return 1

    ok, messages, metrics = check(
        packages_doc, args.api_dir, args.src_root, args.current_phase
    )
    for m in messages:
        print(m)
    for k, v in sorted(metrics.items()):
        print(f"metric {k}={v}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    from simple_yaml import load

    packages = load(
        """
pin: v5.19.2
current_phase: g
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
"""
    )
    with tempfile.TemporaryDirectory() as td:
        api = os.path.join(td, "api")
        os.makedirs(api)
        good_api = """
package: plumbing/hash
phase: 1
require:
  types: []
  functions:
    - New
  semantic:
    - hash.new
zig_map:
  New: hash.new
"""
        with open(os.path.join(api, "plumbing_hash.yaml"), "w", encoding="utf-8") as f:
            f.write(good_api)
        src = os.path.join(td, "src")
        os.makedirs(src)
        ok, msgs, metrics = check(packages, api, src)
        assert ok, msgs
        assert metrics["api.files"] == 1
        assert metrics["api.due_packages"] == 0

        # advance phase without code → fail (API DUE + missing package)
        ok, msgs, metrics = check(packages, api, src, current_override="1")
        assert not ok
        assert metrics["api.mapped_fail"] >= 1
        assert any("API DUE" in m and "zig package missing" in m for m in msgs), msgs

        # hollow empty dir still fails
        pkg = os.path.join(src, "plumbing", "hash")
        os.makedirs(pkg)
        ok, msgs, metrics = check(packages, api, src, current_override="1")
        assert not ok
        assert any("API DUE" in m for m in msgs)

        # zig without symbol token → symbol miss
        with open(os.path.join(pkg, "hash.zig"), "w", encoding="utf-8") as f:
            f.write("pub fn other() void {}\n")
        ok, msgs, metrics = check(packages, api, src, current_override="1")
        assert not ok
        assert any("API symbol not found" in m for m in msgs), msgs
        assert metrics["api.mapped_fail"] >= 1

        # correct symbol → ok
        with open(os.path.join(pkg, "hash.zig"), "w", encoding="utf-8") as f:
            f.write("pub fn new() void {}\n")
        ok, msgs, metrics = check(packages, api, src, current_override="1")
        assert ok, msgs
        assert metrics["api.mapped_ok"] == 1

        # schema error even at phase g
        with open(os.path.join(api, "bad.yaml"), "w", encoding="utf-8") as f:
            f.write("phase: 1\nrequire:\n  functions: notalist\n")
        ok, msgs, metrics = check(packages, api, src)
        assert not ok
        assert metrics["api.schema_errors"] >= 1
        assert any("missing package" in m or "must be a list" in m for m in msgs), msgs
        os.remove(os.path.join(api, "bad.yaml"))

        # due package without any API file
        packages2 = load(
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: plumbing/color
    zig: src/plumbing/color
    phase: 1
    status: required
"""
        )
        # clear api dir of matching package
        for f in os.listdir(api):
            os.remove(os.path.join(api, f))
        with open(os.path.join(api, "other.yaml"), "w", encoding="utf-8") as f:
            f.write(
                """
package: plumbing/hash
phase: 9
require:
  functions: []
"""
            )
        empty_src = os.path.join(td, "src2")
        os.makedirs(empty_src)
        ok, msgs, metrics = check(packages2, api, empty_src, current_override="1")
        assert not ok
        assert metrics["api.missing_for_due"] == 1
        assert any("API inventory missing" in m and "plumbing/color" in m for m in msgs)

    print("check_api_inventory self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
