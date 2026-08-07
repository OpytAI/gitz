"""Minimal YAML subset loader (stdlib only).

Supports the inventory/golden schemas used by gitz:
- mappings (nested)
- sequences of scalars or mappings
- scalars: bare strings, quoted strings, ints, floats, bools, null
- comments (# ...) and blank lines
- multi-line is not supported beyond plain nested indentation

Not a full YAML 1.2 implementation. Keep inventory files simple.
"""

from __future__ import annotations

from typing import Any, List, Optional, Tuple


class YamlError(ValueError):
    pass


def load(text: str) -> Any:
    lines = text.splitlines()
    # Strip full-line comments and trailing whitespace; keep indent.
    cleaned: List[Tuple[int, str]] = []
    for i, raw in enumerate(lines, start=1):
        if not raw.strip():
            continue
        # Remove trailing comments only when not inside quotes (simple).
        line = _strip_comment(raw.rstrip())
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if line.lstrip().startswith("\t"):
            raise YamlError(f"line {i}: tabs not allowed for indent")
        cleaned.append((indent, line.strip()))
    if not cleaned:
        return None
    value, pos = _parse_block(cleaned, 0, cleaned[0][0])
    if pos != len(cleaned):
        raise YamlError(f"trailing content at line index {pos}")
    return value


def load_path(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return load(f.read())


def _strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    for i, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:i].rstrip()
    return line


def _parse_block(lines: List[Tuple[int, str]], pos: int, indent: int) -> Tuple[Any, int]:
    if pos >= len(lines):
        return None, pos
    ind, content = lines[pos]
    if ind < indent:
        return None, pos
    if content.startswith("- "):
        return _parse_list(lines, pos, indent)
    if ":" in content:
        return _parse_map(lines, pos, indent)
    # bare scalar at this level
    return _parse_scalar(content), pos + 1


def _parse_map(lines: List[Tuple[int, str]], pos: int, indent: int) -> Tuple[dict, int]:
    result: dict = {}
    while pos < len(lines):
        ind, content = lines[pos]
        if ind < indent:
            break
        if ind > indent:
            raise YamlError(f"unexpected indent at {content!r}")
        if content.startswith("- "):
            break
        if ":" not in content:
            raise YamlError(f"expected key: value, got {content!r}")
        key, _, rest = content.partition(":")
        key = key.strip()
        rest = rest.strip()
        pos += 1
        if rest == "" or rest == "|" or rest == ">":
            # Nested block or empty value.
            if pos < len(lines) and lines[pos][0] > indent:
                child_indent = lines[pos][0]
                value, pos = _parse_block(lines, pos, child_indent)
            else:
                value = None if rest == "" else rest
        else:
            value = _parse_scalar(rest)
        result[key] = value
    return result, pos


def _parse_list(lines: List[Tuple[int, str]], pos: int, indent: int) -> Tuple[list, int]:
    result: list = []
    while pos < len(lines):
        ind, content = lines[pos]
        if ind < indent:
            break
        if ind > indent:
            raise YamlError(f"unexpected indent in list at {content!r}")
        if not content.startswith("- "):
            break
        item = content[2:].strip()
        pos += 1
        if item == "" or item == "|" or item == ">":
            if pos < len(lines) and lines[pos][0] > indent:
                child_indent = lines[pos][0]
                value, pos = _parse_block(lines, pos, child_indent)
            else:
                value = None
        elif item.endswith(":") and not (item.startswith("'") or item.startswith('"')):
            # Inline map start: "- key:" then nested, or "- key: value"
            # Actually "- key:" has item like "key:" 
            # Treat as map starting at this level with key.
            key = item[:-1].strip()
            if pos < len(lines) and lines[pos][0] > indent:
                child_indent = lines[pos][0]
                nested, pos = _parse_block(lines, pos, child_indent)
                value = {key: nested}
            else:
                value = {key: None}
        elif ":" in item and not item.startswith(("'", '"', "[", "{")):
            # Inline mapping on the list item: "- go: plumbing/hash"
            # May have multiple keys only via nested indent.
            key, _, rest = item.partition(":")
            key = key.strip()
            rest = rest.strip()
            m: dict = {}
            if rest == "":
                if pos < len(lines) and lines[pos][0] > indent:
                    child_indent = lines[pos][0]
                    # Could be nested map fields for this list item
                    # First set key to nested if single nested structure
                    # Actually for "- go: plumbing" style rest is non-empty.
                    nested, pos = _parse_block(lines, pos, child_indent)
                    m[key] = nested
                else:
                    m[key] = None
            else:
                m[key] = _parse_scalar(rest)
            # Consume following keys at greater indent as same list-item map.
            while pos < len(lines) and lines[pos][0] > indent and not lines[pos][1].startswith("- "):
                # parse one map at child indent level, but only keys at the first child indent
                child_indent = lines[pos][0]
                extra, pos = _parse_map(lines, pos, child_indent)
                m.update(extra)
            value = m
        else:
            value = _parse_scalar(item)
            # Following indented map keys attach to a list item that was a scalar? rare.
            # Support list-of-maps form:
            # - go: x
            #   zig: y
            # when first line was "- go: x" handled above.
        result.append(value)
    return result, pos


def _parse_scalar(s: str) -> Any:
    if s == "" or s == "~" or s == "null" or s == "Null" or s == "NULL":
        return None
    if s in ("true", "True", "TRUE", "yes", "Yes"):
        return True
    if s in ("false", "False", "FALSE", "no", "No"):
        return False
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    # int
    try:
        if s.startswith("0") and len(s) > 1 and not s.startswith("0."):
            # keep leading-zero strings as strings (phase ids rarely)
            pass
        else:
            return int(s)
    except ValueError:
        pass
    try:
        if "." in s:
            return float(s)
    except ValueError:
        pass
    # flow list: [a, b, c]
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        if not inner:
            return []
        parts = _split_flow(inner)
        return [_parse_scalar(p.strip()) for p in parts]
    return s


def _split_flow(inner: str) -> List[str]:
    parts: List[str] = []
    buf: List[str] = []
    in_q: Optional[str] = None
    for ch in inner:
        if in_q:
            buf.append(ch)
            if ch == in_q:
                in_q = None
            continue
        if ch in ("'", '"'):
            in_q = ch
            buf.append(ch)
        elif ch == ",":
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf).strip())
    return parts


def self_test() -> None:
    doc = load(
        """
# comment
pin: v5.19.2
current_phase: g
packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
  - go: _examples
    status: excluded
    notes: "examples only"
counts: [1, 2, 3]
flag: true
empty:
"""
    )
    assert doc["pin"] == "v5.19.2"
    assert doc["current_phase"] == "g"
    assert len(doc["packages"]) == 2
    assert doc["packages"][0]["go"] == "plumbing/hash"
    assert doc["packages"][0]["phase"] == 1
    assert doc["packages"][1]["status"] == "excluded"
    assert doc["packages"][1]["notes"] == "examples only"
    assert doc["counts"] == [1, 2, 3]
    assert doc["flag"] is True
    assert doc["empty"] is None

    # nested require style
    api = load(
        """
package: plumbing/hash
phase: 1
require:
  types: []
  functions:
    - New
    - RegisterHash
  semantic:
    - hash.new
zig_map:
  New: hash.new
"""
    )
    assert api["package"] == "plumbing/hash"
    assert api["require"]["functions"] == ["New", "RegisterHash"]
    assert api["zig_map"]["New"] == "hash.new"

    allow = load("entries: []\n")
    assert allow["entries"] == []

    print("simple_yaml self_test OK")


if __name__ == "__main__":
    self_test()
