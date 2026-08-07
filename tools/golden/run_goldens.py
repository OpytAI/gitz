#!/usr/bin/env python3
"""Class A golden runner harness.

Discovers goldens under a root directory. Each golden is a directory containing
meta.yaml:

  name: smoke_identity
  type: file_equals
  actual: input.txt
  expected: expected.txt

Supported types:
  file_equals — byte-for-byte compare of actual vs expected files in the case dir
  text_equals — same as file_equals but normalizes trailing newlines
  static_contains — expected file must be a substring of actual file

Exit 0 if all goldens pass (and at least one was found unless --allow-empty).
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List, Optional, Tuple

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_INV = os.path.join(os.path.dirname(_SCRIPT_DIR), "inventory")
if _INV not in sys.path:
    sys.path.insert(0, _INV)

from simple_yaml import YamlError, load_path  # noqa: E402


def find_meta_files(root: str) -> List[str]:
    metas: List[str] = []
    if not os.path.isdir(root):
        return metas
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn in ("meta.yaml", "meta.yml"):
                metas.append(os.path.join(dirpath, fn))
    return sorted(metas)


def run_case(meta_path: str) -> Tuple[bool, str]:
    case_dir = os.path.dirname(meta_path)
    try:
        doc = load_path(meta_path)
    except (OSError, YamlError) as e:
        return False, f"{meta_path}: load error: {e}"
    if not isinstance(doc, dict):
        return False, f"{meta_path}: meta must be a mapping"

    name = doc.get("name") or os.path.basename(case_dir)
    gtype = doc.get("type") or "file_equals"
    actual_name = doc.get("actual") or "actual.txt"
    expected_name = doc.get("expected") or "expected.txt"

    actual_path = os.path.join(case_dir, actual_name)
    expected_path = os.path.join(case_dir, expected_name)

    if not os.path.isfile(actual_path):
        return False, f"{name}: missing actual file {actual_name}"
    if not os.path.isfile(expected_path):
        return False, f"{name}: missing expected file {expected_name}"

    with open(actual_path, "rb") as f:
        actual = f.read()
    with open(expected_path, "rb") as f:
        expected = f.read()

    if gtype == "file_equals":
        if actual == expected:
            return True, f"PASS {name} (file_equals)"
        return False, (
            f"FAIL {name} (file_equals): actual {len(actual)} bytes "
            f"!= expected {len(expected)} bytes"
        )

    if gtype == "text_equals":
        a = actual.decode("utf-8", errors="replace").rstrip("\n")
        e = expected.decode("utf-8", errors="replace").rstrip("\n")
        if a == e:
            return True, f"PASS {name} (text_equals)"
        return False, f"FAIL {name} (text_equals): content mismatch"

    if gtype == "static_contains":
        if expected in actual:
            return True, f"PASS {name} (static_contains)"
        return False, f"FAIL {name} (static_contains): expected bytes not found in actual"

    return False, f"{name}: unknown golden type {gtype!r}"


def run_all(root: str, allow_empty: bool = False) -> Tuple[bool, List[str], Dict[str, int]]:
    messages: List[str] = []
    metas = find_meta_files(root)
    if not metas:
        if allow_empty:
            messages.append("goldens: none found (allow_empty)")
            return True, messages, {"goldens.count": 0, "goldens.pass": 0, "goldens.fail": 0}
        messages.append(f"FAIL: no goldens found under {root}")
        return False, messages, {"goldens.count": 0, "goldens.pass": 0, "goldens.fail": 0}

    passed = 0
    failed = 0
    for meta in metas:
        ok, msg = run_case(meta)
        messages.append(msg)
        if ok:
            passed += 1
        else:
            failed += 1

    metrics = {
        "goldens.count": len(metas),
        "goldens.pass": passed,
        "goldens.fail": failed,
    }
    ok = failed == 0
    if ok:
        messages.append(f"goldens OK: pass={passed} fail=0")
    return ok, messages, metrics


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--goldens-dir", default=None)
    p.add_argument("--allow-empty", action="store_true")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1

    if not args.goldens_dir:
        p.error("--goldens-dir is required unless --self-test")

    ok, messages, metrics = run_all(args.goldens_dir, allow_empty=args.allow_empty)
    for m in messages:
        print(m)
    for k, v in sorted(metrics.items()):
        print(f"metric {k}={v}")
    return 0 if ok else 1


def _write_case(
    root: str,
    name: str,
    gtype: str,
    actual: str,
    expected: str,
    actual_name: str = "input.txt",
    expected_name: str = "expected.txt",
) -> str:
    case = os.path.join(root, name)
    os.makedirs(case, exist_ok=True)
    with open(os.path.join(case, "meta.yaml"), "w", encoding="utf-8") as f:
        f.write(
            f"name: {name}\ntype: {gtype}\nactual: {actual_name}\nexpected: {expected_name}\n"
        )
    with open(os.path.join(case, actual_name), "w", encoding="utf-8") as f:
        f.write(actual)
    with open(os.path.join(case, expected_name), "w", encoding="utf-8") as f:
        f.write(expected)
    return case


def _self_test() -> bool:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        # file_equals pass + fail
        case = _write_case(td, "fe", "file_equals", "hello\n", "hello\n")
        ok, msgs, metrics = run_all(td)
        assert ok, msgs
        assert metrics["goldens.pass"] == 1
        assert metrics["goldens.fail"] == 0

        with open(os.path.join(case, "expected.txt"), "w", encoding="utf-8") as f:
            f.write("nope\n")
        ok, msgs, metrics = run_all(td)
        assert not ok
        assert metrics["goldens.fail"] == 1
        assert any(m.startswith("FAIL") for m in msgs), msgs

        # clean and test text_equals (trailing newline normalize)
        for name in os.listdir(td):
            import shutil

            shutil.rmtree(os.path.join(td, name))
        _write_case(td, "te", "text_equals", "hello\n\n", "hello")
        ok, msgs, metrics = run_all(td)
        assert ok, msgs
        assert metrics["goldens.pass"] == 1

        with open(os.path.join(td, "te", "expected.txt"), "w", encoding="utf-8") as f:
            f.write("other")
        ok, msgs, metrics = run_all(td)
        assert not ok
        assert any("text_equals" in m and "FAIL" in m for m in msgs)

        # static_contains
        import shutil

        shutil.rmtree(os.path.join(td, "te"))
        _write_case(td, "sc", "static_contains", "abcXYZ123", "XYZ")
        ok, msgs, metrics = run_all(td)
        assert ok, msgs
        with open(os.path.join(td, "sc", "expected.txt"), "w", encoding="utf-8") as f:
            f.write("NOPE")
        ok, msgs, metrics = run_all(td)
        assert not ok
        assert any("static_contains" in m for m in msgs)

        # unknown type
        shutil.rmtree(os.path.join(td, "sc"))
        _write_case(td, "unk", "not_a_type", "a", "a")
        ok, msgs, metrics = run_all(td)
        assert not ok
        assert any("unknown golden type" in m for m in msgs), msgs

        # missing actual
        shutil.rmtree(os.path.join(td, "unk"))
        case = _write_case(td, "miss", "file_equals", "a", "a")
        os.remove(os.path.join(case, "input.txt"))
        ok, msgs, metrics = run_all(td)
        assert not ok
        assert any("missing actual" in m for m in msgs), msgs

        # empty root without allow_empty
        empty = os.path.join(td, "empty_root")
        os.makedirs(empty)
        ok, msgs, metrics = run_all(empty)
        assert not ok
        assert metrics["goldens.count"] == 0
        assert any("no goldens found" in m for m in msgs)

        ok, msgs, metrics = run_all(empty, allow_empty=True)
        assert ok, msgs
        assert metrics["goldens.count"] == 0

        # invalid meta (non-mapping scalar)
        bad = os.path.join(td, "badmeta")
        os.makedirs(bad)
        with open(os.path.join(bad, "meta.yaml"), "w", encoding="utf-8") as f:
            f.write("just-a-string\n")
        ok, msgs, metrics = run_all(bad)
        assert not ok
        assert any("meta must be a mapping" in m for m in msgs), msgs

    print("run_goldens self_test OK")
    return True


if __name__ == "__main__":
    sys.exit(main())
