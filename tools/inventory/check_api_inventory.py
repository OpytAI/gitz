#!/usr/bin/env python3
"""Validate every API inventory and its mapped Zig symbols."""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

from check_file_inventory import zig_rel_to_full
from simple_yaml import YamlError, load, load_path

ENFORCED_STATUSES = frozenset({"required", "deferred"})


def list_api_files(api_dir: str) -> List[str]:
    if not os.path.isdir(api_dir):
        return []
    return [
        os.path.join(api_dir, name)
        for name in sorted(os.listdir(api_dir))
        if name.endswith((".yaml", ".yml"))
    ]


def validate_schema(doc: Dict[str, Any], path: str) -> List[str]:
    errors: List[str] = []
    if not isinstance(doc.get("package"), str) or not doc.get("package"):
        errors.append(f"{path}: missing package")
    required = doc.get("require")
    if not isinstance(required, dict):
        errors.append(f"{path}: require must be a mapping")
    else:
        for key in ("types", "functions", "constants", "semantic"):
            value = required.get(key)
            if value is not None and not isinstance(value, list):
                errors.append(f"{path}: require.{key} must be a list")
            elif isinstance(value, list) and not all(
                isinstance(item, str) for item in value
            ):
                errors.append(f"{path}: require.{key} entries must be strings")
    zig_map = doc.get("zig_map")
    if zig_map is not None and not isinstance(zig_map, dict):
        errors.append(f"{path}: zig_map must be a mapping")
    elif isinstance(zig_map, dict) and not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in zig_map.items()
    ):
        errors.append(f"{path}: zig_map entries must map strings to strings")
    return errors


def load_packages_index(packages_doc: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {
        package["go"]: package
        for package in packages_doc.get("packages") or []
        if isinstance(package, dict) and isinstance(package.get("go"), str)
    }


def read_zig_blob(src_root: str, zig_rel: str) -> str:
    try:
        full = zig_rel_to_full(src_root, zig_rel)
    except ValueError:
        return ""
    if os.path.isfile(full) and full.endswith(".zig"):
        with open(full, "r", encoding="utf-8", errors="replace") as file:
            return file.read()
    if not os.path.isdir(full):
        return ""
    chunks: List[str] = []
    for name in sorted(os.listdir(full)):
        path = os.path.join(full, name)
        if name.endswith(".zig") and os.path.isfile(path):
            with open(path, "r", encoding="utf-8", errors="replace") as file:
                chunks.append(file.read())
    return "\n".join(chunks)


def semantic_ids(doc: Dict[str, Any]) -> List[str]:
    required = doc.get("require") or {}
    identifiers = list(required.get("semantic") or [])
    for value in (doc.get("zig_map") or {}).values():
        if isinstance(value, str) and value not in identifiers:
            identifiers.append(value)
    return identifiers


def check_mapped_presence(doc: Dict[str, Any], zig_text: str) -> List[str]:
    return [
        identifier
        for identifier in semantic_ids(doc)
        if identifier.split(".")[-1] not in zig_text
    ]


def check(
    packages_doc: Dict[str, Any], api_dir: str, src_root: str
) -> Tuple[bool, List[str], Dict[str, Any]]:
    messages: List[str] = []
    package_index = load_packages_index(packages_doc)
    api_files = list_api_files(api_dir)
    api_packages: Set[str] = set()
    schema_errors = 0
    mapped_ok = 0
    mapped_fail = 0
    required_ids = 0
    mapped_ids = 0

    for path in api_files:
        try:
            doc = load_path(path)
        except (OSError, YamlError) as error:
            messages.append(f"error: cannot load {path}: {error}")
            schema_errors += 1
            continue
        if not isinstance(doc, dict):
            messages.append(f"error: {path} root must be a mapping")
            schema_errors += 1
            continue
        errors = validate_schema(doc, path)
        messages.extend(f"error: {error}" for error in errors)
        schema_errors += len(errors)
        package_name = doc.get("package")
        if not isinstance(package_name, str):
            continue
        api_packages.add(package_name)
        if errors:
            continue
        required_ids += len(semantic_ids(doc))
        required = doc.get("require") or {}
        zig_map = doc.get("zig_map") or {}
        for key in ("types", "functions", "constants"):
            mapped_ids += sum(name in zig_map for name in required.get(key) or [])

        package = package_index.get(package_name)
        zig = package.get("zig") if package else None
        if not isinstance(zig, str) or not zig:
            messages.append(
                f"API package has no Zig mapping: package={package_name!r} zig={zig!r}"
            )
            mapped_fail += 1
            continue
        zig_text = read_zig_blob(src_root, zig)
        if not zig_text.strip():
            messages.append(
                f"API package missing or hollow: package={package_name!r} zig={zig!r}"
            )
            mapped_fail += 1
            continue
        missing = check_mapped_presence(doc, zig_text)
        if missing:
            for identifier in missing:
                messages.append(
                    f"API symbol not found in Zig sources: {package_name} id={identifier}"
                )
            mapped_fail += 1
        else:
            mapped_ok += 1

    missing_api = 0
    for name, package in package_index.items():
        if package.get("status", "required") not in ENFORCED_STATUSES:
            continue
        if name not in api_packages:
            messages.append(f"API inventory missing for required package go={name!r}")
            missing_api += 1

    metrics = {
        "api.files": len(api_files),
        "api.packages": len(api_packages),
        "api.schema_errors": schema_errors,
        "api.mapped_ok": mapped_ok,
        "api.mapped_fail": mapped_fail,
        "api.required_ids": required_ids,
        "api.mapped_ids": mapped_ids,
        "api.missing_for_required": missing_api,
    }
    ok = schema_errors == 0 and mapped_fail == 0 and missing_api == 0
    if ok:
        messages.append(
            f"api inventory OK: files={len(api_files)} mapped={mapped_ok} "
            "schema_errors=0"
        )
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages")
    parser.add_argument("--api-dir")
    parser.add_argument("--src-root")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return 0 if _self_test() else 1
    if not args.packages or not args.api_dir or not args.src_root:
        parser.error(
            "--packages, --api-dir, and --src-root are required unless --self-test"
        )
    try:
        packages_doc = load_path(args.packages)
    except (OSError, YamlError) as error:
        print(f"FAIL: packages.yaml: {error}", file=sys.stderr)
        return 1
    if not isinstance(packages_doc, dict):
        print("FAIL: packages.yaml root must be a mapping", file=sys.stderr)
        return 1
    ok, messages, metrics = check(packages_doc, args.api_dir, args.src_root)
    for message in messages:
        print(message)
    for key, value in sorted(metrics.items()):
        print(f"metric {key}={value}")
    return 0 if ok else 1


def _self_test() -> bool:
    import tempfile

    packages = load(
        """
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    status: required
"""
    )
    with tempfile.TemporaryDirectory() as temp_dir:
        api_dir = os.path.join(temp_dir, "api")
        src_dir = os.path.join(temp_dir, "src")
        package_dir = os.path.join(src_dir, "plumbing", "hash")
        os.makedirs(api_dir)
        os.makedirs(package_dir)
        api_path = os.path.join(api_dir, "hash.yaml")
        with open(api_path, "w") as file:
            file.write(
                "package: plumbing/hash\n"
                "require:\n  functions: [New]\n  semantic: [hash.new]\n"
                "zig_map:\n  New: hash.new\n"
            )
        ok, messages, metrics = check(packages, api_dir, src_dir)
        assert not ok, messages
        assert metrics["api.mapped_fail"] == 1

        with open(os.path.join(package_dir, "root.zig"), "w") as file:
            file.write("pub fn new() void {}\n")
        ok, messages, metrics = check(packages, api_dir, src_dir)
        assert ok, messages
        assert metrics["api.mapped_ok"] == 1

        with open(api_path, "w") as file:
            file.write("package: plumbing/hash\nrequire:\n  functions: bad\n")
        ok, messages, metrics = check(packages, api_dir, src_dir)
        assert not ok
        assert metrics["api.schema_errors"] == 1

        os.remove(api_path)
        ok, messages, metrics = check(packages, api_dir, src_dir)
        assert not ok
        assert metrics["api.missing_for_required"] == 1
    print("check_api_inventory self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
