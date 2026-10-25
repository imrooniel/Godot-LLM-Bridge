#!/usr/bin/env python3
"""Version consistency check: the root VERSION file is the single source of
truth and must equal the ``version="..."`` line of every plugin.cfg.

Stdlib only. Paths resolve relative to the repo root (this script lives in
scripts/), never relative to the caller's cwd. Exit 0 with one OK line when
all sources agree; exit 1 with one line per source otherwise. Consumed by
CI and by developers before a release.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
PLUGIN_CFGS = (
    ROOT / "bridge" / "editor_bridge" / "plugin.cfg",
    ROOT / "bridge" / "human_edit" / "plugin.cfg",
)
_CFG_VERSION_RE = re.compile(r'^version="([^"]*)"', re.MULTILINE)


def read_version_file(path: Path) -> "str | None":
    """Return the stripped VERSION contents, or None when the file is absent."""
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip()


def read_cfg_version(path: Path) -> "str | None":
    """Return the plugin.cfg version value, or None when file/line is absent."""
    if not path.is_file():
        return None
    match = _CFG_VERSION_RE.search(path.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def main() -> int:
    version = read_version_file(VERSION_FILE)
    sources = [("VERSION", version)]
    for cfg in PLUGIN_CFGS:
        sources.append((str(cfg.relative_to(ROOT)), read_cfg_version(cfg)))

    if version is not None and all(value == version for _, value in sources):
        print(f"OK: all version sources agree at {version}")
        return 0

    print("MISMATCH: version sources disagree")
    for name, value in sources:
        print(f"  {name}: {value if value is not None else 'MISSING'}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
