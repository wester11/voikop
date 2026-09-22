#!/usr/bin/env python3
"""Validate inactive VOIKOP service catalog lists without changing routing."""

from __future__ import annotations

import json
import ipaddress
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ALL_SERVICES = ROOT.parent / "all-services.domains.txt"
PROFILE_ROOT = ROOT.parent / "profiles"
DOMAIN = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
PROFILE_STATES = frozenset(
    {"CONFIRMED", "EXTERNAL_GEO", "INTERMITTENT", "WATCHLIST", "EXISTING_COMMUNITY_LIST"}
)
# These are infrastructure-provider roots, not a single product.  A product
# can use a provider-specific hostname beneath one of them, but routing the
# provider suffix would capture unrelated customers as well.
SHARED_PROVIDER_SUFFIXES = frozenset(
    {
        "akamai.net",
        "amazonaws.com",
        "azureedge.net",
        "cloudflare.com",
        "cloudfront.net",
        "digitaloceanspaces.com",
        "fastly.net",
        "gcdn.co",
        "gcore.com",
        "googleusercontent.com",
    }
)


def entries(path: Path) -> list[str]:
    return [
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def main() -> int:
    errors: list[str] = []
    owners: dict[str, Path] = {}
    files = sorted(ROOT.glob("*/*.domains.txt"))
    if not files:
        errors.append("no catalog domain lists found")

    all_services_values = entries(ALL_SERVICES)
    if len(all_services_values) != len(set(all_services_values)):
        errors.append("all-services.domains.txt: duplicate domain")
    for value in all_services_values:
        if not DOMAIN.fullmatch(value):
            errors.append(f"all-services.domains.txt: invalid domain {value!r}")
    all_services_set = set(all_services_values)
    for path in files:
        missing = sorted(set(entries(path)) - all_services_set)
        if missing:
            errors.append(
                f"all-services.domains.txt: missing {path.relative_to(ROOT)} entries: "
                + ", ".join(missing)
            )
    for path in files:
        values = entries(path)
        seen: set[str] = set()
        for value in values:
            if not DOMAIN.fullmatch(value):
                errors.append(f"{path.relative_to(ROOT)}: invalid domain {value!r}")
            if value in SHARED_PROVIDER_SUFFIXES:
                errors.append(
                    f"{path.relative_to(ROOT)}: shared-provider suffix is not a service endpoint: {value}"
                )
            if value in seen:
                errors.append(f"{path.relative_to(ROOT)}: duplicate {value}")
            seen.add(value)
            other = owners.get(value)
            if other is not None:
                errors.append(
                    f"{path.relative_to(ROOT)}: duplicated by {other.relative_to(ROOT)}: {value}"
                )
            owners[value] = path

    cidr_files = sorted(ROOT.glob("**/*.cidrs.txt"))
    for path in cidr_files:
        values = entries(path)
        seen_cidrs: set[str] = set()
        for value in values:
            try:
                normalized = str(ipaddress.ip_network(value, strict=False))
            except ValueError:
                errors.append(f"{path.relative_to(ROOT)}: invalid CIDR {value!r}")
                continue
            if normalized != value:
                errors.append(f"{path.relative_to(ROOT)}: non-canonical CIDR {value!r}; use {normalized!r}")
            if normalized in seen_cidrs:
                errors.append(f"{path.relative_to(ROOT)}: duplicate CIDR {normalized}")
            seen_cidrs.add(normalized)

    for path in sorted(PROFILE_ROOT.glob("*.domains.txt")):
        values = entries(path)
        seen: set[str] = set()
        for value in values:
            if not DOMAIN.fullmatch(value):
                errors.append(f"profiles/{path.name}: invalid domain {value!r}")
            if value in seen:
                errors.append(f"profiles/{path.name}: duplicate {value}")
            seen.add(value)

    profile_file = ROOT / "games" / "profiles.json"
    try:
        profiles = json.loads(profile_file.read_text(encoding="utf-8"))["profiles"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        errors.append(f"games/profiles.json: invalid registry: {exc}")
        profiles = []

    ids: set[str] = set()
    for profile in profiles:
        profile_id = profile.get("id") if isinstance(profile, dict) else None
        if not isinstance(profile_id, str) or not profile_id:
            errors.append("games/profiles.json: profile with missing id")
            continue
        if profile_id in ids:
            errors.append(f"games/profiles.json: duplicate profile id {profile_id}")
        ids.add(profile_id)
        status = profile.get("status")
        if status not in PROFILE_STATES:
            errors.append(f"games/profiles.json: {profile_id} has invalid status {status!r}")
        domain_file = profile.get("domains")
        if domain_file is not None and not (ROOT / "games" / domain_file).is_file():
            errors.append(f"games/profiles.json: {profile_id} references missing {domain_file!r}")

    for profile in profiles:
        if not isinstance(profile, dict) or not isinstance(profile.get("id"), str):
            continue
        profile_id = profile["id"]
        components = profile.get("components")
        if not isinstance(components, list):
            errors.append(f"games/profiles.json: {profile_id} components must be a list")
            continue
        for component in components:
            if component not in ids:
                errors.append(f"games/profiles.json: {profile_id} references unknown component {component!r}")
            elif component == profile_id:
                errors.append(f"games/profiles.json: {profile_id} cannot depend on itself")

    games_all = PROFILE_ROOT / "games-all.domains.txt"
    try:
        games_all_entries = entries(games_all)
    except OSError as exc:
        errors.append(f"profiles/games-all.domains.txt: unavailable: {exc}")
        games_all_entries = []
    expected_games_all: list[str] = []
    for path in sorted((ROOT / "games").glob("*.domains.txt")):
        expected_games_all.extend(entries(path))
    if len(games_all_entries) != len(set(games_all_entries)):
        errors.append("profiles/games-all.domains.txt: duplicate domain")
    if set(games_all_entries) != set(expected_games_all):
        missing = sorted(set(expected_games_all) - set(games_all_entries))
        extra = sorted(set(games_all_entries) - set(expected_games_all))
        if missing:
            errors.append("profiles/games-all.domains.txt: missing " + ", ".join(missing))
        if extra:
            errors.append("profiles/games-all.domains.txt: unknown " + ", ".join(extra))

    ai_all = PROFILE_ROOT / "ai-all.domains.txt"
    try:
        ai_all_entries = entries(ai_all)
    except OSError as exc:
        errors.append(f"profiles/ai-all.domains.txt: unavailable: {exc}")
        ai_all_entries = []
    expected_ai_all: list[str] = []
    for path in sorted((ROOT / "ai").glob("*.domains.txt")):
        expected_ai_all.extend(entries(path))
    if len(ai_all_entries) != len(set(ai_all_entries)):
        errors.append("profiles/ai-all.domains.txt: duplicate domain")
    if set(ai_all_entries) != set(expected_ai_all):
        missing = sorted(set(expected_ai_all) - set(ai_all_entries))
        extra = sorted(set(ai_all_entries) - set(expected_ai_all))
        if missing:
            errors.append("profiles/ai-all.domains.txt: missing " + ", ".join(missing))
        if extra:
            errors.append("profiles/ai-all.domains.txt: unknown " + ", ".join(extra))

    registry_path = PROFILE_ROOT / "profiles.json"
    try:
        profile_registry = json.loads(registry_path.read_text(encoding="utf-8"))
        declared_profiles = profile_registry["profiles"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        errors.append(f"profiles/profiles.json: invalid registry: {exc}")
        declared_profiles = []
    profile_ids: set[str] = set()
    for profile in declared_profiles:
        if not isinstance(profile, dict):
            errors.append("profiles/profiles.json: profile must be an object")
            continue
        profile_id = profile.get("id")
        domain_file = profile.get("domains")
        if not isinstance(profile_id, str) or not profile_id:
            errors.append("profiles/profiles.json: profile with missing id")
        elif profile_id in profile_ids:
            errors.append(f"profiles/profiles.json: duplicate profile id {profile_id}")
        else:
            profile_ids.add(profile_id)
        if not isinstance(domain_file, str) or not (PROFILE_ROOT / domain_file).is_file():
            errors.append(f"profiles/profiles.json: invalid domain file for {profile_id!r}")
        if profile.get("default_enabled") is not False:
            errors.append(f"profiles/profiles.json: {profile_id!r} must default to disabled")

    if errors:
        print("Catalog validation failed:")
        print("\n".join(f"- {error}" for error in errors))
        return 1
    print(
        f"Lists valid: {len(all_services_values)} all-services domains include "
        f"{len(files)} individual lists; {len(cidr_files)} CIDR sets checked; "
        f"AI has {len(ai_all_entries)} endpoints and games-all has {len(games_all_entries)}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
