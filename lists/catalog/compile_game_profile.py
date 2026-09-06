#!/usr/bin/env python3
"""Print an inactive composed game profile; never writes router configuration."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

GAMES = Path(__file__).resolve().parent / "games"


def read_domains(path: Path) -> list[str]:
    return [
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", help="profile id from games/profiles.json")
    args = parser.parse_args()
    registry = json.loads((GAMES / "profiles.json").read_text(encoding="utf-8"))
    profiles = {profile["id"]: profile for profile in registry["profiles"]}
    if args.profile not in profiles:
        print(f"Unknown profile: {args.profile}", file=sys.stderr)
        return 2

    resolved: list[str] = []
    seen: set[str] = set()

    def visit(profile_id: str) -> None:
        if profile_id in seen:
            return
        seen.add(profile_id)
        profile = profiles[profile_id]
        for dependency in profile["components"]:
            visit(dependency)
        domain_file = profile["domains"]
        if domain_file:
            resolved.extend(read_domains(GAMES / domain_file))

    visit(args.profile)
    # Keep dependency order stable while avoiding repeated endpoints.
    unique = list(dict.fromkeys(resolved))
    target = profiles[args.profile]
    print(f"# VOIKOP inactive profile: {target['name']} ({target['status']})")
    print("# This output is review material only. It does not configure Podkop/Forkop.")
    print("\n".join(unique))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
