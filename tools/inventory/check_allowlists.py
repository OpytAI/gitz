#!/usr/bin/env python3
"""Allowlist expiry checker.

Fails if any allowlist entry has remove_by_phase <= current_phase.
Also validates required fields: id, reason, remove_by_phase.
Every *.yaml / *.yml under allowlists/ must load as a mapping with an
`entries` list (may be empty). Parse errors and wrong shape fail the check.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from phase_util import phase_rank  # noqa: E402
from simple_yaml import YamlError, load_path  # noqa: E402


def load_entries(allowlists_dir: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    """Return (entries, load_errors). load_errors are fatal for the check."""
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
            if not isinstance(e, dict):
                errors.append(f"error: allowlist {name}: entry must be a mapping, got {e!r}")
                continue
            item = dict(e)
            item["_file"] = name
            entries.append(item)
    return entries, errors


def check(
    packages_path: str,
    allowlists_dir: str,
    current_override: Optional[str] = None,
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    try:
        packages_doc = load_path(packages_path)
    except (OSError, YamlError) as e:
        return False, [f"error: packages.yaml: {e}"], {}

    current = current_override or packages_doc.get("current_phase")
    if current is None:
        return False, ["error: current_phase missing"], {}

    entries, load_errors = load_entries(allowlists_dir)
    messages.extend(load_errors)
    overdue = 0
    invalid = len(load_errors)
    for e in entries:
        for field in ("id", "reason", "remove_by_phase"):
            if field not in e or e[field] is None or e[field] == "":
                messages.append(
                    f"error: allowlist entry in {e.get('_file')} missing {field}: {e!r}"
                )
                invalid += 1
                break
        else:
            try:
                if phase_rank(e["remove_by_phase"]) <= phase_rank(current):
                    messages.append(
                        f"OVERDUE allowlist id={e['id']!r} "
                        f"remove_by_phase={e['remove_by_phase']} "
                        f"current_phase={current} file={e.get('_file')}"
                    )
                    overdue += 1
            except ValueError as ex:
                messages.append(f"error: bad phase in {e.get('_file')}: {ex}")
                invalid += 1

    metrics = {
        "allowlist.active": len(entries),
        "allowlist.overdue": overdue,
        "allowlist.invalid": invalid,
        "current_phase": current,
    }
    ok = overdue == 0 and invalid == 0
    if ok:
        messages.append(
            f"allowlists OK: active={metrics['allowlist.active']} overdue=0 "
            f"current_phase={current}"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--packages", default=None)
    p.add_argument("--allowlists-dir", default=None)
    p.add_argument("--current-phase", default=None)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1

    if not args.packages or not args.allowlists_dir:
        p.error("--packages and --allowlists-dir are required unless --self-test")

    ok, messages, metrics = check(args.packages, args.allowlists_dir, args.current_phase)
    for m in messages:
        print(m)
    for k, v in sorted(metrics.items()):
        print(f"metric {k}={v}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        packages = os.path.join(td, "packages.yaml")
        with open(packages, "w", encoding="utf-8") as f:
            f.write("pin: v5.19.2\ncurrent_phase: g\npackages: []\n")
        ad = os.path.join(td, "allowlists")
        os.makedirs(ad)
        with open(os.path.join(ad, "seed.yaml"), "w", encoding="utf-8") as f:
            f.write("entries: []\n")
        ok, msgs, m = check(packages, ad)
        assert ok, msgs
        assert m["allowlist.active"] == 0
        assert m["allowlist.overdue"] == 0

        # future remove_by_phase must pass
        with open(os.path.join(ad, "future.yaml"), "w", encoding="utf-8") as f:
            f.write(
                """
entries:
  - id: packfile.Encoder
    reason: write path later
    remove_by_phase: 5
"""
            )
        ok, msgs, m = check(packages, ad)
        assert ok, msgs
        assert m["allowlist.active"] == 1
        assert m["allowlist.overdue"] == 0

        # overdue at boundary remove_by_phase: g with current g
        with open(os.path.join(ad, "overdue.yaml"), "w", encoding="utf-8") as f:
            f.write(
                """
entries:
  - id: foo.bar
    reason: temp
    remove_by_phase: g
"""
            )
        ok, msgs, m = check(packages, ad)
        assert not ok
        assert m["allowlist.overdue"] == 1
        assert any("OVERDUE" in x and "foo.bar" in x for x in msgs), msgs

        # missing required field
        os.remove(os.path.join(ad, "overdue.yaml"))
        with open(os.path.join(ad, "incomplete.yaml"), "w", encoding="utf-8") as f:
            f.write(
                """
entries:
  - id: only.id
    reason: no remove phase
"""
            )
        ok, msgs, m = check(packages, ad)
        assert not ok
        assert m["allowlist.invalid"] >= 1
        assert any("missing remove_by_phase" in x for x in msgs), msgs

        # garbage / wrong shape must fail (not silent ignore)
        os.remove(os.path.join(ad, "incomplete.yaml"))
        with open(os.path.join(ad, "garbage.yaml"), "w", encoding="utf-8") as f:
            f.write("not a mapping with entries\n")
        ok, msgs, m = check(packages, ad)
        assert not ok
        assert m["allowlist.invalid"] >= 1
        assert any("error:" in x and "garbage.yaml" in x for x in msgs), msgs

        # bad phase string
        os.remove(os.path.join(ad, "garbage.yaml"))
        with open(os.path.join(ad, "badphase.yaml"), "w", encoding="utf-8") as f:
            f.write(
                """
entries:
  - id: z
    reason: r
    remove_by_phase: not-a-phase
"""
            )
        ok, msgs, m = check(packages, ad)
        assert not ok
        assert any("bad phase" in x for x in msgs), msgs

    print("check_allowlists self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
