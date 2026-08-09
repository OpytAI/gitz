#!/usr/bin/env python3
"""Validate temporary-gap allowlists."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

from simple_yaml import YamlError, load_path


def load_entries(directory: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    entries: List[Dict[str, Any]] = []
    errors: List[str] = []
    if not os.path.isdir(directory):
        return entries, errors
    for name in sorted(os.listdir(directory)):
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(directory, name)
        try:
            doc = load_path(path)
        except (OSError, YamlError) as error:
            errors.append(f"error: cannot load allowlist {name}: {error}")
            continue
        if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
            errors.append(
                f"error: allowlist {name}: root must contain an entries list"
            )
            continue
        for entry in doc["entries"]:
            if not isinstance(entry, dict):
                errors.append(
                    f"error: allowlist {name}: entry must be a mapping, got {entry!r}"
                )
                continue
            item = dict(entry)
            item["_file"] = name
            entries.append(item)
    return entries, errors


def check(directory: str) -> Tuple[bool, List[str], Dict[str, Any]]:
    entries, messages = load_entries(directory)
    invalid = len(messages)
    seen: set[str] = set()
    for entry in entries:
        for field in ("id", "reason"):
            if not entry.get(field):
                messages.append(
                    f"error: allowlist entry in {entry.get('_file')} missing {field}: "
                    f"{entry!r}"
                )
                invalid += 1
                break
        entry_id = entry.get("id")
        if isinstance(entry_id, str):
            if entry_id in seen:
                messages.append(f"error: duplicate allowlist id={entry_id!r}")
                invalid += 1
            seen.add(entry_id)
    metrics = {"allowlist.active": len(entries), "allowlist.invalid": invalid}
    ok = invalid == 0
    if ok:
        messages.append(f"allowlists OK: active={len(entries)} invalid=0")
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allowlists-dir")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return 0 if _self_test() else 1
    if not args.allowlists_dir:
        parser.error("--allowlists-dir is required unless --self-test")
    ok, messages, metrics = check(args.allowlists_dir)
    for message in messages:
        print(message)
    for key, value in sorted(metrics.items()):
        print(f"metric {key}={value}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    with tempfile.TemporaryDirectory() as temp_dir:
        seed = os.path.join(temp_dir, "seed.yaml")
        with open(seed, "w") as file:
            file.write("entries: []\n")
        ok, messages, metrics = check(temp_dir)
        assert ok, messages
        assert metrics["allowlist.active"] == 0

        with open(seed, "w") as file:
            file.write("entries:\n  - id: gap\n    reason: temporary\n")
        ok, messages, metrics = check(temp_dir)
        assert ok, messages
        assert metrics["allowlist.active"] == 1

        with open(seed, "w") as file:
            file.write("entries:\n  - id: gap\n")
        ok, messages, _ = check(temp_dir)
        assert not ok
        assert any("missing reason" in message for message in messages)
    print("check_allowlists self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
