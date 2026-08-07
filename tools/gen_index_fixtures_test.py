"""//tools:gen_index_fixtures_test — committed fixtures match the generator.

Data deps (Bazel runfiles only):
  //data:fixtures
  //src/plumbing/format/index:package_srcs
"""
from __future__ import annotations

import os
import unittest
from pathlib import Path

import gen_index_fixtures as gen


def _workspace_root() -> Path:
    runfiles = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR")
    if not runfiles:
        raise RuntimeError(
            "RUNFILES_DIR/TEST_SRCDIR unset — run via "
            "`bazel test //tools:gen_index_fixtures_test`"
        )
    ws = os.environ.get("TEST_WORKSPACE", "_main")
    for name in (ws, "_main", "gitz"):
        candidate = Path(runfiles) / name
        if candidate.is_dir():
            return candidate
    raise RuntimeError(f"cannot resolve workspace under runfiles={runfiles}")


class GenIndexFixturesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = _workspace_root()
        cls.images = gen.build_all()

    def test_committed_binaries_match(self) -> None:
        fixdir = self.root / "data" / "fixtures" / "index"
        self.assertTrue(fixdir.is_dir(), f"missing {fixdir}")
        for name, want in self.images.items():
            path = fixdir / name
            self.assertTrue(path.is_file(), f"missing {path}")
            got = path.read_bytes()
            self.assertEqual(
                got,
                want,
                f"{name}: diverged from //tools:gen_index_fixtures; "
                f"bazel run //tools:gen_index_fixtures -- "
                f"--outdir $$PWD/data/fixtures/index",
            )

    def test_committed_hex_match(self) -> None:
        fixdir = self.root / "data" / "fixtures" / "index"
        for name, want in self.images.items():
            path = fixdir / f"{name}.hex"
            self.assertTrue(path.is_file(), f"missing {path}")
            hx = path.read_text(encoding="ascii").strip()
            self.assertEqual(bytes.fromhex(hx), want, f"{name}.hex mismatch")

    def test_fixtures_zig_embed_match(self) -> None:
        zig = (
            self.root
            / "src"
            / "plumbing"
            / "format"
            / "index"
            / "fixtures.zig"
        )
        self.assertTrue(zig.is_file(), f"missing {zig}")
        text = zig.read_text(encoding="utf-8")
        for name, want in self.images.items():
            got = gen.extract_zig_raw(text, name)
            self.assertEqual(
                got,
                want,
                f"fixtures.zig {name}_raw diverged; "
                f"bazel run //tools:gen_index_fixtures -- "
                f"--outdir $$PWD/data/fixtures/index "
                f"--embed $$PWD/src/plumbing/format/index/fixtures.zig",
            )


if __name__ == "__main__":
    unittest.main()
