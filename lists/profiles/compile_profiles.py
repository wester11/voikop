#!/usr/bin/env python3
"""Build opt-in profiles from canonical catalog service lists."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROFILE = ROOT / "profiles" / "ai-all.domains.txt"
SOURCE = ROOT / "catalog" / "ai"


def entries(path: Path) -> set[str]:
    return {
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def main() -> int:
    domains: set[str] = set()
    for path in sorted(SOURCE.glob("*.domains.txt")):
        domains.update(entries(path))
    header = [
        "# VOIKOP profile: All AI",
        "#",
        "# Generated from lists/catalog/ai/*.domains.txt by compile_profiles.py.",
        "# This profile is future-use only and is not enabled on a router automatically.",
        "",
    ]
    PROFILE.write_text("\n".join(header + sorted(domains)) + "\n", encoding="utf-8", newline="\n")
    print(f"AI profile compiled: {len(domains)} domains from {len(list(SOURCE.glob('*.domains.txt')))} services")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
