#!/usr/bin/env python3
"""Refresh the public ZeroBlock v1 source snapshot.

The ZeroBlock package resolves these lists from itdoginfo/allow-domains when
the RouteRich v2 API is unavailable.  This script deliberately writes only to
this isolated upstream directory: it must never modify the active ORBIT list.
"""

from __future__ import annotations

import ipaddress
import json
import re
import sys
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
COMMIT = "24c3137ef5cec388d9964fbe6661c32082a17b9e"
RAW = f"https://raw.githubusercontent.com/itdoginfo/allow-domains/{COMMIT}"

DOMAIN_SOURCES = {
    "regional/russia-inside.domains.txt": "Russia/inside-raw.lst",
    "regional/russia-outside.domains.txt": "Russia/outside-raw.lst",
    "regional/ukraine-inside.domains.txt": "Ukraine/inside-raw.lst",
    "categories/anime.domains.txt": "Categories/anime.lst",
    "categories/block.domains.txt": "Categories/block.lst",
    "categories/geoblock.domains.txt": "Categories/geoblock.lst",
    "categories/news.domains.txt": "Categories/news.lst",
    "categories/porn.domains.txt": "Categories/porn.lst",
    "services/cloudflare.domains.txt": "Services/cloudflare.lst",
    "services/discord.domains.txt": "Services/discord.lst",
    "services/google-ai.domains.txt": "Services/google_ai.lst",
    "services/google-play.domains.txt": "Services/google_play.lst",
    "services/hdrezka.domains.txt": "Services/hdrezka.lst",
    "services/meta.domains.txt": "Services/meta.lst",
    "services/telegram.domains.txt": "Services/telegram.lst",
    "services/tiktok.domains.txt": "Services/tiktok.lst",
    "services/twitter.domains.txt": "Services/twitter.lst",
    "services/youtube.domains.txt": "Services/youtube.lst",
}

CIDR_SOURCES = {
    "ipv4/cloudflare.cidrs.txt": "Subnets/IPv4/cloudflare.lst",
    "ipv4/discord.cidrs.txt": "Subnets/IPv4/discord.lst",
    "ipv4/meta.cidrs.txt": "Subnets/IPv4/meta.lst",
    "ipv4/telegram.cidrs.txt": "Subnets/IPv4/telegram.lst",
    "ipv4/twitter.cidrs.txt": "Subnets/IPv4/twitter.lst",
    "ipv6/cloudflare.cidrs.txt": "Subnets/IPv6/cloudflare.lst",
    "ipv6/discord.cidrs.txt": "Subnets/IPv6/discord.lst",
    "ipv6/meta.cidrs.txt": "Subnets/IPv6/meta.lst",
    "ipv6/telegram.cidrs.txt": "Subnets/IPv6/telegram.lst",
    "ipv6/twitter.cidrs.txt": "Subnets/IPv6/twitter.lst",
}

LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
DOMAIN = re.compile(rf"^(?:\.[a-z]{{2,63}}|(?:{LABEL}\.)+{LABEL})$")


def fetch(relative_path: str) -> list[str]:
    request = urllib.request.Request(
        f"{RAW}/{relative_path}", headers={"User-Agent": "VOIKOP-ZeroBlock-Snapshot/1"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read().decode("utf-8")
    if raw.lstrip().lower().startswith("<!doctype html"):
        raise RuntimeError(f"{relative_path}: HTML received instead of a list")
    values = [line.strip().lower() for line in raw.splitlines() if line.strip() and not line.startswith("#")]
    if not values:
        raise RuntimeError(f"{relative_path}: empty list")
    return values


def write(relative_path: str, values: list[str]) -> None:
    target = ROOT / "v1" / relative_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(values) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    all_domains: set[str] = set()
    manifest_domains: list[dict[str, object]] = []
    for output, source in DOMAIN_SOURCES.items():
        values = fetch(source)
        invalid = [value for value in values if not DOMAIN.fullmatch(value)]
        if invalid:
            raise RuntimeError(f"{source}: invalid domain entries: {', '.join(invalid[:3])}")
        values = sorted(set(values))
        write(output, values)
        all_domains.update(values)
        manifest_domains.append({"file": output, "source": source, "entries": len(values)})

    all_ipv4: set[str] = set()
    all_ipv6: set[str] = set()
    manifest_cidrs: list[dict[str, object]] = []
    for output, source in CIDR_SOURCES.items():
        values = fetch(source)
        parsed = []
        for value in values:
            network = ipaddress.ip_network(value, strict=False)
            parsed.append(str(network))
        values = sorted(set(parsed), key=lambda value: (int(ipaddress.ip_network(value).network_address), value))
        write(output, values)
        (all_ipv4 if output.startswith("ipv4/") else all_ipv6).update(values)
        manifest_cidrs.append({"file": output, "source": source, "entries": len(values)})

    write("all.domains.txt", sorted(all_domains))
    write("all.ipv4.cidrs.txt", sorted(all_ipv4, key=lambda value: (int(ipaddress.ip_network(value).network_address), value)))
    write("all.ipv6.cidrs.txt", sorted(all_ipv6, key=lambda value: (int(ipaddress.ip_network(value).network_address), value)))
    manifest = {
        "upstream": "itdoginfo/allow-domains",
        "commit": COMMIT,
        "source_base": RAW,
        "domains": manifest_domains,
        "cidrs": manifest_cidrs,
        "combined": {
            "all.domains.txt": len(all_domains),
            "all.ipv4.cidrs.txt": len(all_ipv4),
            "all.ipv6.cidrs.txt": len(all_ipv6),
        },
    }
    (ROOT / "v1" / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    print(f"ZeroBlock v1 snapshot refreshed: {len(all_domains)} domains, {len(all_ipv4)} IPv4 CIDRs, {len(all_ipv6)} IPv6 CIDRs")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"ZeroBlock snapshot failed: {error}", file=sys.stderr)
        raise SystemExit(1)
