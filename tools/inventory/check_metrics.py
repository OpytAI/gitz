#!/usr/bin/env python3
"""Compute repository quality metrics and enforce their thresholds."""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

from check_allowlists import load_entries
from check_file_inventory import ENFORCED_STATUSES, package_has_zig
from simple_yaml import YamlError, load_path


def parse_pin_from_md(path: str) -> Optional[str]:
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as file:
        text = file.read()
    match = re.search(r"\|\s*Pin\s*\|\s*`?([^`|\s]+)`?\s*\|", text)
    if match:
        return match.group(1).strip()
    match = re.search(r"\bv\d+\.\d+\.\d+\b", text)
    return match.group(0) if match else None


def count_goldens(goldens_dir: str) -> int:
    if not os.path.isdir(goldens_dir):
        return 0
    return sum(
        name in ("meta.yaml", "meta.yml") or name.endswith(".expected")
        for _root, _dirs, files in os.walk(goldens_dir)
        for name in files
    )


def compute_api_mapped_ratio(api_dir: str) -> Tuple[float, int, int, int]:
    files = 0
    required_names = 0
    mapped_names = 0
    if not os.path.isdir(api_dir):
        return 1.0, files, required_names, mapped_names
    for name in sorted(os.listdir(api_dir)):
        if not name.endswith((".yaml", ".yml")):
            continue
        try:
            doc = load_path(os.path.join(api_dir, name))
        except (OSError, YamlError):
            continue
        if not isinstance(doc, dict):
            continue
        files += 1
        required = doc.get("require") or {}
        zig_map = doc.get("zig_map") or {}
        if not isinstance(required, dict) or not isinstance(zig_map, dict):
            continue
        names: List[str] = []
        for key in ("types", "functions", "constants"):
            values = required.get(key) or []
            if isinstance(values, list):
                names.extend(value for value in values if isinstance(value, str))
        required_names += len(names)
        mapped_names += sum(item in zig_map for item in names)
    ratio = mapped_names / required_names if required_names else 1.0
    return ratio, files, required_names, mapped_names


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
        config = load_path(metrics_path)
    except (OSError, YamlError) as error:
        return False, [f"error: load failed: {error}"], {}
    if not isinstance(packages_doc, dict) or not isinstance(config, dict):
        return False, ["error: metric inputs must be mappings"], {}

    packages = packages_doc.get("packages") or []
    required = [
        package
        for package in packages
        if isinstance(package, dict)
        and package.get("status", "required") in ENFORCED_STATUSES
    ]
    missing = [
        package
        for package in required
        if not package_has_zig(src_root, package.get("zig") or "")
    ]
    pin = packages_doc.get("pin")
    pin_md = parse_pin_from_md(pin_md_path)
    mapped_ratio, api_files, required_names, mapped_names = (
        compute_api_mapped_ratio(api_dir)
    )
    golden_count = count_goldens(goldens_dir)
    allow_entries, allow_errors = load_entries(allowlists_dir)
    messages.extend(allow_errors)

    metrics: Dict[str, Any] = {
        "go_git.pin": pin,
        "go_git.pin_md": pin_md,
        "packages.total": len(packages),
        "packages.required": len(required),
        "packages.present": len(required) - len(missing),
        "packages.missing": len(missing),
        "api.files": api_files,
        "api.required_names": required_names,
        "api.mapped_names": mapped_names,
        "api.mapped_ratio": round(mapped_ratio, 4),
        "goldens.count": golden_count,
        "allowlist.active": len(allow_entries),
    }

    expected_pin = (config.get("pin") or {}).get("expected")
    if expected_pin and pin != expected_pin:
        messages.append(
            f"FAIL pin packages.yaml={pin!r} != metrics expected={expected_pin!r}"
        )
    if pin_md and pin and pin_md != pin:
        messages.append(
            f"FAIL pin GO_GIT_PIN.md={pin_md!r} != packages.yaml={pin!r}"
        )

    package_config = config.get("packages") or {}
    for metric, threshold in (
        ("packages.total", "min_total"),
        ("packages.required", "min_required"),
    ):
        minimum = int(package_config.get(threshold) or 0)
        if metrics[metric] < minimum:
            messages.append(f"FAIL {metric}={metrics[metric]} < {threshold}={minimum}")
    maximum_missing = int(package_config.get("max_missing") or 0)
    if len(missing) > maximum_missing:
        messages.append(
            f"FAIL packages.missing={len(missing)} > max_missing={maximum_missing}"
        )

    api_config = config.get("api") or {}
    minimum_files = int(api_config.get("min_files") or 0)
    if api_files < minimum_files:
        messages.append(f"FAIL api.files={api_files} < min_files={minimum_files}")
    minimum_ratio = float(api_config.get("min_mapped_ratio") or 0.0)
    if mapped_ratio + 1e-9 < minimum_ratio:
        messages.append(
            f"FAIL api.mapped_ratio={mapped_ratio:.4f} "
            f"< min_mapped_ratio={minimum_ratio}"
        )

    minimum_goldens = int((config.get("goldens") or {}).get("min_count") or 0)
    if golden_count < minimum_goldens:
        messages.append(
            f"FAIL goldens.count={golden_count} < min_count={minimum_goldens}"
        )

    maximum_active = int((config.get("allowlists") or {}).get("max_active") or 0)
    if len(allow_entries) > maximum_active:
        messages.append(
            f"FAIL allowlist.active={len(allow_entries)} > max_active={maximum_active}"
        )

    ok = not any(
        message.startswith("error:") or message.startswith("FAIL")
        for message in messages
    )
    if ok:
        messages.append(
            f"metrics OK: pin={pin} packages.total={len(packages)} "
            f"goldens={golden_count} allowlist.active={len(allow_entries)} "
            f"mapped_ratio={mapped_ratio:.4f}"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in (
        "packages",
        "metrics",
        "api-dir",
        "allowlists-dir",
        "goldens-dir",
        "pin-md",
        "src-root",
    ):
        parser.add_argument(f"--{option}")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return 0 if _self_test() else 1
    values = (
        args.packages,
        args.metrics,
        args.api_dir,
        args.allowlists_dir,
        args.goldens_dir,
        args.pin_md,
        args.src_root,
    )
    if not all(values):
        parser.error("all path flags are required unless --self-test")
    ok, messages, metrics = check(*values)
    for message in messages:
        print(message)
    for key, value in sorted(metrics.items()):
        print(f"metric {key}={value}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    def write(path: str, text: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as file:
            file.write(text)

    with tempfile.TemporaryDirectory() as temp_dir:
        packages = os.path.join(temp_dir, "packages.yaml")
        config = os.path.join(temp_dir, "metrics.yaml")
        api_dir = os.path.join(temp_dir, "api")
        allowlists = os.path.join(temp_dir, "allowlists")
        goldens = os.path.join(temp_dir, "goldens")
        pin_md = os.path.join(temp_dir, "PIN.md")
        src = os.path.join(temp_dir, "src")
        write(
            packages,
            "pin: v5.19.2\npackages:\n  - go: demo\n"
            "    zig: src/demo\n    status: required\n",
        )
        write(
            config,
            "pin:\n  expected: v5.19.2\npackages:\n  min_total: 1\n"
            "  min_required: 1\n  max_missing: 0\napi:\n  min_files: 1\n"
            "  min_mapped_ratio: 1.0\ngoldens:\n  min_count: 1\n"
            "allowlists:\n  max_active: 0\n",
        )
        write(
            os.path.join(api_dir, "demo.yaml"),
            "package: demo\nrequire:\n  functions:\n    - New\n"
            "zig_map:\n  New: demo.new\n",
        )
        write(os.path.join(allowlists, "seed.yaml"), "entries: []\n")
        write(os.path.join(goldens, "smoke", "meta.yaml"), "name: smoke\n")
        write(pin_md, "| Pin | `v5.19.2` |\n")

        ok, messages, metrics = check(
            packages, config, api_dir, allowlists, goldens, pin_md, src
        )
        assert not ok, messages
        assert metrics["packages.missing"] == 1

        write(os.path.join(src, "demo", "root.zig"), "pub fn new() void {}\n")
        ok, messages, metrics = check(
            packages, config, api_dir, allowlists, goldens, pin_md, src
        )
        assert ok, messages
        assert metrics["api.mapped_ratio"] == 1.0

        write(os.path.join(allowlists, "seed.yaml"), "entries:\n  - id: gap\n    reason: temporary\n")
        ok, messages, _ = check(
            packages, config, api_dir, allowlists, goldens, pin_md, src
        )
        assert not ok
        assert any("allowlist.active" in message for message in messages)
    print("check_metrics self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
