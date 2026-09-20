#!/usr/bin/env python3
"""Compose canonical service files from the pinned ZeroBlock v1 snapshot.

This is intentionally a research-only import.  It does not update the active
ORBIT Full list or configure a router.
"""

from __future__ import annotations

import ipaddress
from pathlib import Path


CATALOG = Path(__file__).resolve().parent
V1 = CATALOG.parent / "upstreams" / "zeroblock" / "v1"

DOMAIN_MAP = {
    "social/discord.domains.txt": "services/discord.domains.txt",
    "social/meta.domains.txt": "services/meta.domains.txt",
    "social/tiktok.domains.txt": "services/tiktok.domains.txt",
    "social/x-twitter.domains.txt": "services/twitter.domains.txt",
    "services/google-play.domains.txt": "services/google-play.domains.txt",
    "services/hdrezka.domains.txt": "services/hdrezka.domains.txt",
    "services/youtube.domains.txt": "services/youtube.domains.txt",
}

CIDR_MAP = {
    "social/discord.zeroblock.cidrs.txt": ("ipv4/discord.cidrs.txt", "ipv6/discord.cidrs.txt"),
    "social/meta.zeroblock.cidrs.txt": ("ipv4/meta.cidrs.txt", "ipv6/meta.cidrs.txt"),
    "social/x-twitter.zeroblock.cidrs.txt": ("ipv4/twitter.cidrs.txt", "ipv6/twitter.cidrs.txt"),
}

TELEGRAM_PROVIDER_DOMAINS = {
    "cdn-telegram.org", "comments.app", "contest.com", "fragment.com", "graph.org",
    "quiz.directory", "t.me", "tdesktop.com", "telega.one", "telegra.ph",
    "telegram-cdn.org", "telegram.dog", "telegram.me", "telegram.org", "telegram.space",
    "telesco.pe", "tg.dev", "ton.org", "tx.me", "usercontent.dev",
}
TELEGRAM_PROVIDER_CIDRS = {
    "91.108.56.0/22", "91.108.4.0/22", "91.108.8.0/21", "91.108.16.0/21",
    "91.108.12.0/22", "149.154.160.0/20", "91.105.192.0/23", "91.108.20.0/22",
    "185.76.151.0/24", "2001:b28:f23d::/48", "2001:b28:f23f::/48",
    "2001:67c:4e8::/48", "2001:b28:f23c::/48", "2a0a:f280::/32",
}


def entries(path: Path) -> set[str]:
    return {
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def write(path: Path, heading: str, values: set[str], note: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header = [f"# {heading}", "# Source: pinned ZeroBlock v1 snapshot (itdoginfo/allow-domains)."]
    if note:
        header.append(f"# {note}")
    path.write_text("\n".join(header + [""] + sorted(values)) + "\n", encoding="utf-8", newline="\n")


def cidrs(paths: tuple[str, ...]) -> set[str]:
    parsed = {ipaddress.ip_network(item, strict=False) for path in paths for item in entries(V1 / path)}
    return collapse(parsed)


def collapse(networks: set[ipaddress._BaseNetwork]) -> set[str]:
    collapsed: set[str] = set()
    for version in (4, 6):
        same_version = [network for network in networks if network.version == version]
        collapsed.update(str(network) for network in ipaddress.collapse_addresses(same_version))
    return collapsed


def main() -> int:
    for target, source in DOMAIN_MAP.items():
        write(CATALOG / target, target.removesuffix(".domains.txt").replace("/", " / "), entries(V1 / source))

    for target, sources in CIDR_MAP.items():
        write(
            CATALOG / target,
            target.removesuffix(".cidrs.txt").replace("/", " / "),
            cidrs(sources),
            "Raw upstream networks; not approved for automatic routing because a service may use shared infrastructure.",
        )

    telegram_domains = TELEGRAM_PROVIDER_DOMAINS | entries(V1 / "services/telegram.domains.txt")
    write(CATALOG / "social/telegram.domains.txt", "social / telegram", telegram_domains)
    telegram_cidrs = {ipaddress.ip_network(item, strict=False) for item in TELEGRAM_PROVIDER_CIDRS}
    telegram_cidrs.update(ipaddress.ip_network(item, strict=False) for item in entries(V1 / "ipv4/telegram.cidrs.txt"))
    telegram_cidrs.update(ipaddress.ip_network(item, strict=False) for item in entries(V1 / "ipv6/telegram.cidrs.txt"))
    write(
        CATALOG / "social/telegram.cidrs.txt",
        "social / telegram",
        collapse(telegram_cidrs),
        "Union of Telegram-published CIDRs and the pinned ZeroBlock v1 snapshot.",
    )
    print(f"ZeroBlock service groups composed: {len(DOMAIN_MAP) + 1} domain sets, {len(CIDR_MAP) + 1} network sets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
