#!/usr/bin/env python3
"""Emit vectors.zig with string constants for each Class A expected dump."""

from __future__ import annotations

import argparse
import pathlib
import sys


def zig_string(s: str) -> str:
    """Encode s as a Zig double-quoted string with escapes."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 32 or o == 127:
            out.append(f"\\x{o:02x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument(
        "pairs",
        nargs="+",
        help="suite=path/to/expected.txt",
    )
    args = p.parse_args()

    lines = [
        "//! Auto-generated expected golden payloads for recompute_test.",
        "//! Do not edit by hand — produced by gen_vectors.py from data/goldens.",
        "",
    ]
    for pair in args.pairs:
        suite, path = pair.split("=", 1)
        text = pathlib.Path(path).read_text(encoding="utf-8")
        lines.append(f"pub const {suite} = {zig_string(text)};")
        lines.append("")

    pathlib.Path(args.out).write_text("\n".join(lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
