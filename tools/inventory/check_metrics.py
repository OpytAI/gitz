#!/usr/bin/env python3
"""Metrics emission and threshold checks.

Reads packages.yaml, metrics.yaml, api/, allowlists/, goldens dir, GO_GIT_PIN.md.
Fails if thresholds are not met or allowlist entries are overdue.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from phase_util import phase_due, phase_rank  # noqa: E402
from simple_yaml import YamlError, load_path  # noqa: E402

ENFORCED_STATUSES = frozenset({"required", "deferred"})


def parse_pin_from_md(path: str) -> Optional[str]:
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"\|\s*Pin\s*\|\s*`?([^`|\s]+)`?\s*\|", text)
    if m:
        return m.group(1).strip()
    m = re.search(r"\bv\d+\.\d+\.\d+\b", text)
    return m.group(0) if m else None


def count_goldens(goldens_dir: str) -> int:
    if not os.path.isdir(goldens_dir):
        return 0
    n = 0
    for root, _dirs, files in os.walk(goldens_dir):
        for f in files:
            if f in ("meta.yaml", "meta.yml") or f.endswith(".expected"):
                n += 1
    return n


def package_has_zig(src_root: str, zig_rel: str) -> bool:
    """Non-recursive: package root needs a direct *.zig (not only in child dirs)."""
    if zig_rel.startswith("src/"):
        rel = zig_rel[len("src/") :]
    elif zig_rel == "src":
        rel = ""
    else:
        rel = zig_rel
    full = os.path.join(src_root, rel) if rel else src_root
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


def load_allowlist_entries(
    allowlists_dir: str,
) -> Tuple[List[Dict[str, Any]], List[str]]:
    """Strict loader: every *.yaml must be mapping with entries list."""
    entries: List[Dict[str, Any]] = []
    errors: List[str] = []
    if not os.path.isdir(allowlists_dir):
        return entries, errors
    for name in sorted(os.listdir(allowlists_dir)):
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(allowlists_dir, name)
        try:
            doc = load_path(path)
        except (OSError, YamlError) as e:
            errors.append(f"error: cannot load allowlist {name}: {e}")
            continue
        if not isinstance(doc, dict):
            errors.append(
                f"error: allowlist {name}: root must be a mapping with entries: []"
            )
            continue
        if "entries" not in doc:
            errors.append(f"error: allowlist {name}: missing 'entries' key")
            continue
        if not isinstance(doc["entries"], list):
            errors.append(f"error: allowlist {name}: 'entries' must be a list")
            continue
        for e in doc["entries"]:
            if isinstance(e, dict):
                item = dict(e)
                item["_file"] = name
                entries.append(item)
            else:
                errors.append(
                    f"error: allowlist {name}: entry must be a mapping, got {e!r}"
                )
    return entries, errors


def compute_api_mapped_ratio(api_dir: str, current: Any) -> Tuple[float, int, int, int]:
    """Return (ratio, due_packages, required_names, mapped_names) for due API files.

    ratio = mapped_names / required_names when required_names > 0, else 1.0.
    """
    if not os.path.isdir(api_dir):
        return 1.0, 0, 0, 0
    due = 0
    required_names = 0
    mapped_names = 0
    for name in sorted(os.listdir(api_dir)):
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(api_dir, name)
        try:
            doc = load_path(path)
        except (OSError, YamlError):
            continue
        if not isinstance(doc, dict):
            continue
        phase = doc.get("phase")
        if phase is None or not phase_due(phase, current):
            continue
        due += 1
        req = doc.get("require") or {}
        zmap = doc.get("zig_map") or {}
        names: List[str] = []
        for key in ("types", "functions", "constants"):
            names.extend(req.get(key) or [])
        required_names += len(names)
        for n in names:
            if n in zmap:
                mapped_names += 1
    if required_names == 0:
        return 1.0, due, 0, 0
    return mapped_names / required_names, due, required_names, mapped_names


def check(
    packages_path: str,
    metrics_path: str,
    api_dir: str,
    allowlists_dir: str,
    goldens_dir: str,
    pin_md_path: str,
    src_root: str,
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    try:
        packages_doc = load_path(packages_path)
        metrics_cfg = load_path(metrics_path)
    except (OSError, YamlError) as e:
        return False, [f"error: load failed: {e}"], {}

    packages = packages_doc.get("packages") or []
    current = packages_doc.get("current_phase")
    pin = packages_doc.get("pin")

    required = [p for p in packages if p.get("status") in ENFORCED_STATUSES]
    required_due = [
        p
        for p in required
        if p.get("phase") is not None and phase_due(p["phase"], current)
    ]
    missing = []
    for p in required_due:
        zig = p.get("zig") or ""
        if not package_has_zig(src_root, zig):
            missing.append(p)

    api_files = 0
    if os.path.isdir(api_dir):
        api_files = len(
            [f for f in os.listdir(api_dir) if f.endswith((".yaml", ".yml"))]
        )

    goldens_count = count_goldens(goldens_dir)
    allow_entries, allow_errors = load_allowlist_entries(allowlists_dir)
    messages.extend(allow_errors)

    overdue = []
    for e in allow_entries:
        rbp = e.get("remove_by_phase")
        if rbp is None:
            messages.append(
                f"error: allowlist entry {e.get('id')!r} missing remove_by_phase "
                f"in {e.get('_file')}"
            )
            continue
        try:
            if phase_rank(rbp) <= phase_rank(current):
                overdue.append(e)
        except ValueError as ex:
            messages.append(f"error: allowlist bad phase in {e.get('_file')}: {ex}")

    pin_md = parse_pin_from_md(pin_md_path)
    mapped_ratio, api_due, api_req_names, api_mapped_names = compute_api_mapped_ratio(
        api_dir, current
    )

    metrics: Dict[str, Any] = {
        "go_git.pin": pin,
        "go_git.pin_md": pin_md,
        "current_phase": current,
        "packages.total": len(packages),
        "packages.required": len(required),
        "packages.required_due": len(required_due),
        "packages.present": len(required_due) - len(missing),
        "packages.missing": len(missing),
        "api.files": api_files,
        "api.due_packages": api_due,
        "api.required_names": api_req_names,
        "api.mapped_names": api_mapped_names,
        "api.mapped_ratio": round(mapped_ratio, 4),
        "goldens.count": goldens_count,
        "allowlist.active": len(allow_entries),
        "allowlist.overdue": len(overdue),
    }

    thr_pin = (metrics_cfg.get("pin") or {}).get("expected")
    if thr_pin and pin != thr_pin:
        messages.append(f"FAIL pin packages.yaml={pin!r} != metrics expected={thr_pin!r}")
    if pin_md and pin and pin_md != pin:
        messages.append(f"FAIL pin GO_GIT_PIN.md={pin_md!r} != packages.yaml={pin!r}")

    allowed = (metrics_cfg.get("current_phase") or {}).get("allowed") or []
    allowed_norm = {str(a) for a in allowed}
    if current is not None and str(current) not in allowed_norm:
        messages.append(
            f"FAIL current_phase={current!r} not in allowed {sorted(allowed_norm)}"
        )

    pkg_thr = metrics_cfg.get("packages") or {}
    if len(packages) < int(pkg_thr.get("min_total") or 0):
        messages.append(
            f"FAIL packages.total={len(packages)} < min_total={pkg_thr.get('min_total')}"
        )
    if len(required) < int(pkg_thr.get("min_required") or 0):
        messages.append(
            f"FAIL packages.required={len(required)} < min_required={pkg_thr.get('min_required')}"
        )
    if len(missing) > int(pkg_thr.get("max_missing") or 0):
        messages.append(
            f"FAIL packages.missing={len(missing)} > max_missing={pkg_thr.get('max_missing')}"
        )

    api_thr = metrics_cfg.get("api") or {}
    if api_files < int(api_thr.get("min_files") or 0):
        messages.append(
            f"FAIL api.files={api_files} < min_files={api_thr.get('min_files')}"
        )
    min_ratio = float(api_thr.get("min_mapped_ratio") or 0.0)
    if api_req_names > 0 and mapped_ratio + 1e-9 < min_ratio:
        messages.append(
            f"FAIL api.mapped_ratio={mapped_ratio:.4f} < min_mapped_ratio={min_ratio} "
            f"(mapped={api_mapped_names} required_names={api_req_names} due={api_due})"
        )

    g_thr = metrics_cfg.get("goldens") or {}
    if goldens_count < int(g_thr.get("min_count") or 0):
        messages.append(
            f"FAIL goldens.count={goldens_count} < min_count={g_thr.get('min_count')}"
        )

    a_thr = metrics_cfg.get("allowlists") or {}
    max_overdue = int(a_thr.get("max_overdue") or 0)
    if len(overdue) > max_overdue:
        for e in overdue:
            messages.append(
                f"FAIL overdue allowlist id={e.get('id')!r} "
                f"remove_by_phase={e.get('remove_by_phase')} current_phase={current}"
            )

    hard_errors = [m for m in messages if m.startswith("error:")]
    fails = [m for m in messages if m.startswith("FAIL")]
    ok = not hard_errors and not fails

    if ok:
        messages.append(
            f"metrics OK: pin={pin} current_phase={current} "
            f"packages.total={len(packages)} goldens={goldens_count} "
            f"allowlist.active={len(allow_entries)} mapped_ratio={mapped_ratio:.4f}"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--packages", default=None)
    p.add_argument("--metrics", default=None)
    p.add_argument("--api-dir", default=None)
    p.add_argument("--allowlists-dir", default=None)
    p.add_argument("--goldens-dir", default=None)
    p.add_argument("--pin-md", default=None)
    p.add_argument("--src-root", default=None)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1

    need = [
        args.packages,
        args.metrics,
        args.api_dir,
        args.allowlists_dir,
        args.goldens_dir,
        args.pin_md,
        args.src_root,
    ]
    if not all(need):
        p.error("all path flags are required unless --self-test")

    ok, messages, metrics = check(
        args.packages,
        args.metrics,
        args.api_dir,
        args.allowlists_dir,
        args.goldens_dir,
        args.pin_md,
        args.src_root,
    )
    for m in messages:
        print(m)
    for k, v in sorted(metrics.items()):
        print(f"metric {k}={v}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    def write(path: str, text: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    with tempfile.TemporaryDirectory() as td:
        packages = os.path.join(td, "packages.yaml")
        metrics_yaml = os.path.join(td, "metrics.yaml")
        api_dir = os.path.join(td, "api")
        allow_dir = os.path.join(td, "allowlists")
        goldens = os.path.join(td, "goldens", "smoke")
        pin_md = os.path.join(td, "GO_GIT_PIN.md")
        src = os.path.join(td, "src")
        os.makedirs(api_dir)
        os.makedirs(allow_dir)
        os.makedirs(goldens)
        os.makedirs(src)

        write(
            packages,
            """
pin: v5.19.2
current_phase: g
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
""",
        )
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 1
  min_required: 1
  max_missing: 0
api:
  min_files: 1
  min_mapped_ratio: 0.0
goldens:
  min_count: 1
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g, "1"]
""",
        )
        write(
            os.path.join(api_dir, "plumbing_hash.yaml"),
            """
package: plumbing/hash
phase: 1
require:
  types: []
  functions:
    - New
  constants: []
zig_map:
  New: hash.new
""",
        )
        write(os.path.join(allow_dir, "seed.yaml"), "entries: []\n")
        write(os.path.join(goldens, "meta.yaml"), "name: s\ntype: file_equals\n")
        write(pin_md, "| Pin | `v5.19.2` |\n")

        # 1) minimal valid tree at phase g
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert ok, msgs
        assert m["packages.missing"] == 0
        assert m["api.files"] == 1
        assert m["goldens.count"] == 1

        # 2) pin mismatch vs metrics expected
        write(packages, "pin: v0.0.0\ncurrent_phase: g\npackages: []\n")
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 0
api:
  min_files: 0
  min_mapped_ratio: 0.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert any("FAIL pin packages.yaml" in x for x in msgs), msgs

        # restore pin; fail pin vs GO_GIT_PIN.md
        write(packages, "pin: v5.19.2\ncurrent_phase: g\npackages: []\n")
        write(pin_md, "| Pin | `v9.9.9` |\n")
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 0
api:
  min_files: 0
  min_mapped_ratio: 0.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert any("GO_GIT_PIN.md" in x for x in msgs), msgs
        write(pin_md, "| Pin | `v5.19.2` |\n")

        # 3) max_missing when phase advanced
        write(
            packages,
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
""",
        )
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 1
  min_required: 1
  max_missing: 0
api:
  min_files: 0
  min_mapped_ratio: 0.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g, "1"]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert m["packages.missing"] == 1
        assert any("packages.missing" in x for x in msgs), msgs

        # hollow dir still missing
        os.makedirs(os.path.join(src, "plumbing", "hash"), exist_ok=True)
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert m["packages.missing"] == 1

        # 4) overdue allowlist
        write(packages, "pin: v5.19.2\ncurrent_phase: g\npackages: []\n")
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 0
api:
  min_files: 0
  min_mapped_ratio: 0.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g]
""",
        )
        write(
            os.path.join(allow_dir, "overdue.yaml"),
            """
entries:
  - id: foo.bar
    reason: temp
    remove_by_phase: g
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert m["allowlist.overdue"] == 1
        assert any("overdue allowlist id='foo.bar'" in x for x in msgs), msgs
        os.remove(os.path.join(allow_dir, "overdue.yaml"))

        # 5) goldens / api.files below mins
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 0
api:
  min_files: 99
  min_mapped_ratio: 0.0
goldens:
  min_count: 99
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert any("api.files" in x for x in msgs)
        assert any("goldens.count" in x for x in msgs)

        # 6) min_mapped_ratio when due
        write(
            packages,
            """
pin: v5.19.2
current_phase: 1
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
""",
        )
        # API has function New without zig_map → ratio 0
        write(
            os.path.join(api_dir, "plumbing_hash.yaml"),
            """
package: plumbing/hash
phase: 1
require:
  functions:
    - New
zig_map: {}
""",
        )
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 99
api:
  min_files: 1
  min_mapped_ratio: 1.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g, "1"]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert any("mapped_ratio" in x for x in msgs), msgs
        assert m["api.mapped_ratio"] == 0.0

        # garbage allowlist fails
        write(os.path.join(allow_dir, "garbage.yaml"), "just a string\n")
        write(
            metrics_yaml,
            """
pin:
  expected: v5.19.2
packages:
  min_total: 0
  min_required: 0
  max_missing: 99
api:
  min_files: 0
  min_mapped_ratio: 0.0
goldens:
  min_count: 0
allowlists:
  max_overdue: 0
current_phase:
  allowed: [g, "1"]
""",
        )
        ok, msgs, m = check(
            packages, metrics_yaml, api_dir, allow_dir, os.path.join(td, "goldens"), pin_md, src
        )
        assert not ok
        assert any("allowlist garbage.yaml" in x for x in msgs), msgs

    print("check_metrics self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
