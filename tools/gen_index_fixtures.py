"""Generate Phase 5 index (DIRC) fixtures.

Entry point: Bazel only.

  bazel run //tools:gen_index_fixtures -- --outdir <dir>
  bazel run //tools:gen_index_fixtures -- --outdir <dir> --embed <fixtures.zig>
  bazel test //tools:gen_index_fixtures_test
  bazel build //tools:index_fixture_images

Synthetic images match the gitz / go-git Encoder layout:

  DIRC header | version | entry_count | entries | SHA-1 trailer

Pad model (go-git encodeEntryName + padEntry for V2/V3):

  * Write path bytes only (no mandatory extra NUL after the name).
  * Then pad with ``8 - wrote % 8`` zero bytes (always 1–8).
  * ``wrote`` = fixed entry header (62) [+ 2 extended flags for V3] + name len.

V4 name wire (encodeEntryNameV4): VLQ(strip) + suffix + NUL; no 8-byte pad.

No host interpreter path. No default source-tree write without flags.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
from pathlib import Path

ENTRY_HEADER = 62
ENTRY_EXTENDED = 0x4000
NAME_MASK = 0xFFF
INTENT = 1 << 13
SKIP = 1 << 14
MODE = 0o100644
SAMPLE = bytes.fromhex("32858aad3c383ed1ff0a0f9bdf231d54a00c9e88")
ZERO = b"\x00" * 20
ZIG_BYTES_PER_LINE = 16

SYNTHETIC_NAMES = ("v2_simple", "v3_intent", "v4_prefix")
EXPECTED_VERSIONS = {"v2_simple": 2, "v3_intent": 3, "v4_prefix": 4}


def be32(v: int) -> bytes:
    return struct.pack(">I", v)


def be16(v: int) -> bytes:
    return struct.pack(">H", v)


def pad(wrote: int) -> bytes:
    """go-git padEntry: padLen = 8 - wrote%8 (1..8 zeros). V2/V3 only."""
    return b"\x00" * (8 - wrote % 8)


def vlq(n: int) -> bytes:
    stack = bytearray()
    val = n
    stack.append(val & 0x7F)
    val >>= 7
    while val != 0:
        val -= 1
        stack.append(0x80 | (val & 0x7F))
        val >>= 7
    stack.reverse()
    return bytes(stack)


def v2_entry(
    name: bytes,
    h: bytes,
    size: int,
    cs: int = 1480626693,
    cn: int = 498593596,
    ms: int = 1480626693,
    mn: int = 498593596,
) -> bytes:
    o = bytearray()
    o += be32(cs) + be32(cn) + be32(ms) + be32(mn)
    o += be32(0) + be32(0) + be32(MODE) + be32(0) + be32(0) + be32(size)
    o += h
    o += be16(min(len(name), NAME_MASK))
    o += name
    o += pad(ENTRY_HEADER + len(name))
    return bytes(o)


def v3_ext(
    name: bytes,
    h: bytes,
    size: int,
    ita: bool = False,
    sw: bool = False,
) -> bytes:
    o = bytearray()
    o += be32(1) + be32(0) + be32(1) + be32(0)
    o += be32(0) + be32(0) + be32(MODE) + be32(0) + be32(0) + be32(size)
    o += h
    o += be16(ENTRY_EXTENDED | min(len(name), NAME_MASK))
    ext = 0
    if ita:
        ext |= INTENT
    if sw:
        ext |= SKIP
    o += be16(ext)
    o += name
    o += pad(ENTRY_HEADER + 2 + len(name))
    return bytes(o)


def v4_entry(name: bytes, prev: bytes, h: bytes, size: int) -> bytes:
    o = bytearray()
    o += be32(1) + be32(0) + be32(1) + be32(0)
    o += be32(0) + be32(0) + be32(MODE) + be32(0) + be32(0) + be32(size)
    o += h
    o += be16(min(len(name), NAME_MASK))
    if not prev:
        prefix, strip = 0, 0
    else:
        prefix = 0
        n = min(len(prev), len(name))
        while prefix < n and prev[prefix] == name[prefix]:
            prefix += 1
        strip = len(prev) - prefix
    o += vlq(strip)
    o += name[prefix:]
    o += b"\x00"
    return bytes(o)


def finish(body: bytes) -> bytes:
    return body + hashlib.sha1(body).digest()


def build_v2() -> bytes:
    body = bytearray(b"DIRC" + be32(2) + be32(3))
    body += v2_entry(b".gitignore", SAMPLE, 189)
    body += v2_entry(b"CHANGELOG", ZERO, 42)
    body += v2_entry(b"README.md", SAMPLE, 1024)
    return finish(bytes(body))


def build_v3() -> bytes:
    body = bytearray(b"DIRC" + be32(3) + be32(4))
    body += v2_entry(b"a.txt", SAMPLE, 10, 1, 0, 1, 0)
    body += v3_ext(b"intent-to-add", ZERO, 0, ita=True)
    body += v3_ext(b"skip-me", ZERO, 0, sw=True)
    body += v3_ext(b"z-both", SAMPLE, 7, ita=True, sw=True)
    return finish(bytes(body))


def build_v4() -> bytes:
    names = sorted(
        [
            b".gitignore",
            b"src/foo.go",
            b"src/foo_test.go",
            b"src/bar.go",
            b"src/bar/baz.go",
            b"vendor/foo.go",
            b"vendor/foo/bar.go",
        ]
    )
    body = bytearray(b"DIRC" + be32(4) + be32(len(names)))
    prev = b""
    for i, name in enumerate(names):
        body += v4_entry(name, prev, SAMPLE if i % 2 == 0 else ZERO, i + 1)
        prev = name
    return finish(bytes(body))


def build_all() -> dict[str, bytes]:
    return {
        "v2_simple": build_v2(),
        "v3_intent": build_v3(),
        "v4_prefix": build_v4(),
    }


def write_hex(path: Path, data: bytes) -> None:
    path.write_text(data.hex() + "\n", encoding="ascii")


def zig_byte_array(data: bytes) -> str:
    lines: list[str] = []
    for i in range(0, len(data), ZIG_BYTES_PER_LINE):
        chunk = data[i : i + ZIG_BYTES_PER_LINE]
        parts = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    {parts},")
    return "\n".join(lines)


def extract_zig_raw(text: str, name: str) -> bytes:
    m = re.search(
        rf"const {re.escape(name)}_raw = \[_\]u8\{{([^}}]+)\}}",
        text,
        re.DOTALL,
    )
    if not m:
        raise SystemExit(f"const {name}_raw not found in fixtures.zig")
    nums = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)", m.group(1))]
    return bytes(nums)


def embed_fixtures_zig(path: Path, images: dict[str, bytes]) -> None:
    if not path.is_file():
        raise SystemExit(f"missing {path}")
    text = path.read_text(encoding="utf-8")
    for name, data in images.items():
        pattern = re.compile(
            rf"(const {re.escape(name)}_raw = \[_\]u8\{{)\n.*?\n(\}};)",
            re.DOTALL,
        )
        body = zig_byte_array(data)
        replacement = rf"\1\n{body}\n\2"
        new_text, n = pattern.subn(replacement, text, count=1)
        if n != 1:
            raise SystemExit(
                f"failed to rewrite const {name}_raw in {path} (matches={n})"
            )
        text = new_text
    path.write_text(text, encoding="utf-8")
    print(f"embedded {', '.join(images)} into {path}")


def check_dir(outdir: Path, images: dict[str, bytes]) -> None:
    if not outdir.is_dir():
        raise SystemExit(f"--check dir missing: {outdir}")
    for name, want in images.items():
        path = outdir / name
        if not path.is_file():
            raise SystemExit(f"missing fixture binary: {path}")
        got = path.read_bytes()
        if got != want:
            raise SystemExit(
                f"fixture mismatch {name}: len got={len(got)} want={len(want)}"
            )
        hex_path = outdir / f"{name}.hex"
        if hex_path.is_file():
            hx = hex_path.read_text(encoding="ascii").strip()
            if bytes.fromhex(hx) != want:
                raise SystemExit(f"hex mismatch {name}")
        print(f"ok {name} ({len(want)} bytes)")
    print("check dir: all synthetic fixtures match generator")


def check_embed(path: Path, images: dict[str, bytes]) -> None:
    text = path.read_text(encoding="utf-8")
    for name, want in images.items():
        got = extract_zig_raw(text, name)
        if got != want:
            raise SystemExit(
                f"fixtures.zig {name}_raw mismatch: "
                f"len got={len(got)} want={len(want)}"
            )
        print(f"ok embed {name}_raw ({len(want)} bytes)")
    print(f"check embed: {path} matches generator")


def write_outdir(outdir: Path, images: dict[str, bytes]) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    for name, data in images.items():
        ver = EXPECTED_VERSIONS[name]
        path = outdir / name
        path.write_bytes(data)
        write_hex(outdir / f"{name}.hex", data)
        if data[:4] != b"DIRC":
            raise SystemExit(f"{name}: bad signature")
        if struct.unpack(">I", data[4:8])[0] != ver:
            raise SystemExit(f"{name}: bad version")
        if hashlib.sha1(data[:-20]).digest() != data[-20:]:
            raise SystemExit(f"{name}: bad trailer")
        print(f"wrote {path} + {name}.hex ({len(data)} bytes) version={ver}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate/check Phase 5 index DIRC fixtures. "
            "Invoke only via Bazel: bazel run //tools:gen_index_fixtures"
        )
    )
    parser.add_argument(
        "--outdir",
        type=Path,
        help="write synthetic binary+.hex fixtures into this directory",
    )
    parser.add_argument(
        "--check",
        type=Path,
        metavar="DIR",
        help="verify DIR fixtures match this generator (no writes)",
    )
    parser.add_argument(
        "--check-embed",
        type=Path,
        metavar="FIXTURES_ZIG",
        help="verify fixtures.zig *_raw arrays match this generator",
    )
    parser.add_argument(
        "--embed",
        type=Path,
        metavar="FIXTURES_ZIG",
        help="rewrite fixtures.zig *_raw arrays (use with bazel run + absolute path)",
    )
    parser.add_argument(
        "--print",
        choices=SYNTHETIC_NAMES,
        metavar="NAME",
        help="print continuous hex of one synthetic fixture to stdout",
    )
    args = parser.parse_args(argv)
    images = build_all()

    if args.print:
        sys.stdout.write(images[args.print].hex())
        return 0

    did = False
    if args.outdir is not None:
        write_outdir(args.outdir, images)
        did = True
    if args.check is not None:
        check_dir(args.check, images)
        did = True
    if args.check_embed is not None:
        check_embed(args.check_embed, images)
        did = True
    if args.embed is not None:
        embed_fixtures_zig(args.embed, images)
        did = True

    if not did:
        parser.error(
            "require one of --outdir / --check / --check-embed / --embed / --print "
            "(Bazel: bazel run //tools:gen_index_fixtures -- …)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
