#!/usr/bin/env python3
"""Generate the inactive all-games profile from catalog source lists.

This tool writes review material only. It never configures Podkop, Forkop,
ZeroBlock, ORBIT, or a router.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ipaddress
import os
import re
import secrets
import stat
import sys
from pathlib import Path

from validate_catalog import SHARED_PROVIDER_SUFFIXES

CATALOG_ROOT = Path(__file__).resolve().parent
GAMES_ROOT = CATALOG_ROOT / "games"
OUTPUT = CATALOG_ROOT.parent / "profiles" / "games-all.domains.txt"
MAX_SOURCE_BYTES = 1_048_576
MAX_TOTAL_SOURCE_BYTES = 8_388_608
MAX_SOURCE_FILES = 256
MAX_DOMAINS = 20_000
MAX_DOMAIN_LENGTH = 253
HAS_DIRECTORY_FD = os.name == "posix" and os.open in os.supports_dir_fd
LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
ASCII_TLD = re.compile(r"^[a-z]{2,63}$")
NON_PUBLIC_SUFFIXES = frozenset(
    {"localhost", "local", "test", "example", "invalid", "onion", "home.arpa"}
)

# These suffixes are shared infrastructure. Specific hostnames may be useful
# candidates, but they require human review and must not be confused with a
# provider-wide routing rule. The list is intentionally warning-only except
# for the bare provider suffixes rejected by validate_catalog.
SHARED_INFRASTRUCTURE_SUFFIXES = frozenset(
    {
        "akamaized.net",
        "akamaihd.net",
        "amazonaws.com",
        "azureedge.net",
        "cloudflare.com",
        "cloudflare.net",
        "cloudfront.net",
        "edgesuite.net",
        "fastly-edge.com",
        "fastly.net",
        "gcore.com",
        "gcdn.co",
        "googleusercontent.com",
    }
)

HEADER = (
    "# VOIKOP profile: All catalogued games\n"
    "#\n"
    "# Generated deterministically from lists/catalog/games/*.domains.txt.\n"
    "# This opt-in, future-use profile combines publisher, launcher, game,\n"
    "# account and exact CDN endpoints. It is not fetched or enabled by\n"
    "# ORBIT, Podkop, Forkop or ZeroBlock today.\n"
)


class CatalogError(ValueError):
    """A game source list is malformed or outside the supported policy."""


def _canonical_domain(raw_value: str, source: Path, line_number: int) -> str:
    value = raw_value.strip()
    if not value:
        raise CatalogError(f"{source}:{line_number}: empty domain")
    if not value.isascii():
        raise CatalogError(
            f"{source}:{line_number}: Unicode IDN is not accepted; provide a reviewed ASCII A-label"
        )
    value = value.lower()
    if len(value) > MAX_DOMAIN_LENGTH:
        raise CatalogError(f"{source}:{line_number}: domain exceeds {MAX_DOMAIN_LENGTH} bytes")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise CatalogError(f"{source}:{line_number}: IP literals are not valid game-domain entries")

    labels = value.split(".")
    if len(labels) < 2 or any(not LABEL.fullmatch(label) for label in labels):
        raise CatalogError(f"{source}:{line_number}: invalid domain {raw_value!r}")
    if any(value == suffix or value.endswith("." + suffix) for suffix in NON_PUBLIC_SUFFIXES):
        raise CatalogError(f"{source}:{line_number}: reserved non-public suffix in {value!r}")
    tld = labels[-1]
    if tld.startswith("xn--"):
        raise CatalogError(
            f"{source}:{line_number}: IDN public suffixes are unsupported by the existing catalog validator"
        )
    if not ASCII_TLD.fullmatch(tld):
        raise CatalogError(f"{source}:{line_number}: invalid public suffix {tld!r}")

    for label in labels:
        if label.startswith("xn--"):
            try:
                decoded = label.encode("ascii").decode("idna")
                if decoded.encode("idna").decode("ascii").lower() != label:
                    raise CatalogError(f"{source}:{line_number}: non-canonical IDN A-label {label!r}")
            except UnicodeError as exc:
                raise CatalogError(f"{source}:{line_number}: invalid IDN A-label {label!r}") from exc
    if value in SHARED_PROVIDER_SUFFIXES:
        raise CatalogError(f"{source}:{line_number}: provider-wide shared suffix is forbidden: {value}")
    return value


def _checked_directory(path: Path, label: str) -> Path:
    """Resolve an existing directory and reject symlinks/reparse redirection."""
    try:
        if path.is_symlink():
            raise CatalogError(f"{label}: symbolic-link directories are not accepted")
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise CatalogError(f"{label}: directory cannot be safely resolved: {exc}") from exc
    if not resolved.is_dir():
        raise CatalogError(f"{label}: expected an existing directory")

    lexical = Path(os.path.abspath(os.fspath(path)))
    if os.path.normcase(os.fspath(lexical)) != os.path.normcase(os.fspath(resolved)):
        raise CatalogError(f"{label}: symbolic-link or redirected path component")
    return resolved


def _validated_output_path(
    path: Path, expected_parent: Path | None = None
) -> tuple[Path, tuple[int, int]]:
    """Return an output path under a verified, non-symlinked parent directory."""
    before = path.parent.stat(follow_symlinks=False)
    identity = (before.st_dev, before.st_ino)
    resolved_parent = _checked_directory(path.parent, "generated profile parent")
    if expected_parent is not None:
        expected_resolved = _checked_directory(expected_parent, "expected profile parent")
        if resolved_parent != expected_resolved:
            raise CatalogError("generated profile parent is outside the expected catalog directory")
        expected_root = _checked_directory(CATALOG_ROOT.parent, "catalog root")
        if expected_resolved.parent != expected_root:
            raise CatalogError("expected profile parent is outside the catalog root")

    try:
        if path.is_symlink():
            raise CatalogError("generated profile must not be a symbolic link")
        resolved_existing = path.resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise CatalogError(f"generated profile path cannot be safely resolved: {exc}") from exc
    if resolved_existing.parent != resolved_parent:
        raise CatalogError("generated profile resolves outside its verified parent")
    after = resolved_parent.stat(follow_symlinks=False)
    if (after.st_dev, after.st_ino) != identity:
        raise CatalogError("generated profile parent changed during validation")
    return resolved_parent / path.name, identity


@contextmanager
def _directory_handle(path: Path, label: str, expected_identity: tuple[int, int] | None = None):
    """Anchor every path component without following a substituted symlink."""
    if not HAS_DIRECTORY_FD:
        raise CatalogError("secure catalog file access requires POSIX dir_fd support; use Linux or WSL")
    lexical = Path(os.path.abspath(os.fspath(path)))
    prefixes = [Path("/")]
    for component in lexical.parts[1:]:
        prefixes.append(prefixes[-1] / component)
    # Establish identities before any open. Comparing only two observations
    # after open would accept a replacement made between resolve and open.
    snapshots = []
    for prefix in prefixes:
        before = prefix.stat(follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise CatalogError(f"{label}: symbolic-link directories are not accepted")
        if not stat.S_ISDIR(before.st_mode):
            raise CatalogError(f"{label}: expected directory path components")
        snapshots.append((before.st_dev, before.st_ino))
    resolved = _checked_directory(path, label)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open("/", flags)
    try:
        root = os.fstat(descriptor)
        if (root.st_dev, root.st_ino) != snapshots[0]:
            raise CatalogError(f"{label}: root changed while opening")
        for index, component in enumerate(resolved.parts[1:], 1):
            child = os.open(component, flags, dir_fd=descriptor)
            opened_child = os.fstat(child)
            if (opened_child.st_dev, opened_child.st_ino) != snapshots[index]:
                os.close(child)
                raise CatalogError(f"{label}: directory changed while opening")
            os.close(descriptor)
            descriptor = child
        current = resolved.stat(follow_symlinks=False)
        opened = os.fstat(descriptor)
        if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
            raise CatalogError(f"{label}: directory changed during validation")
        if expected_identity is not None and (opened.st_dev, opened.st_ino) != expected_identity:
            raise CatalogError(f"{label}: validated directory identity changed before open")
        yield descriptor
    except OSError as exc:
        raise CatalogError(f"{label}: secure directory access failed: {exc}") from exc
    finally:
        os.close(descriptor)


def _read_regular(parent: int, name: str, source: Path, limit: int) -> bytes:
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode):
        raise CatalogError(f"{source}: symbolic-link sources are not accepted")
    if not stat.S_ISREG(before.st_mode):
        raise CatalogError(f"{source}: source must be a regular file")
    if before.st_size > limit:
        raise CatalogError(f"{source}: source exceeds {limit} bytes")
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except OSError as exc:
        raise CatalogError(f"{source}: source changed before reading: {exc}") from exc
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
        if identity(before) != identity(opened) or not stat.S_ISREG(opened.st_mode):
            raise CatalogError(f"{source}: source changed before reading")
        payload = stream.read(limit + 1)
        if len(payload) > limit:
            raise CatalogError(f"{source}: source exceeds {limit} bytes")
        if identity(opened) != identity(os.fstat(stream.fileno())):
            raise CatalogError(f"{source}: source changed during reading")
        return payload


def _source_payloads(source_dir: Path) -> list[tuple[Path, bytes]]:
    payloads = []
    total = 0
    with _directory_handle(source_dir, "game source directory") as parent:
        files = sorted(name for name in os.listdir(parent) if name.endswith(".domains.txt"))
        if not files:
            raise CatalogError(f"no game domain lists found in {source_dir}")
        if len(files) > MAX_SOURCE_FILES:
            raise CatalogError(f"too many game source files: {len(files)} > {MAX_SOURCE_FILES}")
        for name in files:
            path = source_dir / name
            payload = _read_regular(parent, name, path, MAX_SOURCE_BYTES)
            total += len(payload)
            if total > MAX_TOTAL_SOURCE_BYTES:
                raise CatalogError(f"game sources exceed {MAX_TOTAL_SOURCE_BYTES} aggregate bytes")
            payloads.append((path, payload))
    return payloads


def collect_domains(source_dir: Path) -> tuple[list[str], list[str]]:

    domains: set[str] = set()
    warnings: set[str] = set()
    for path, payload in _source_payloads(source_dir):
        try:
            text = payload.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise CatalogError(f"{path}: source is not valid UTF-8") from exc
        for line_number, line in enumerate(text.splitlines(), 1):
            value = line.strip()
            if not value or value.startswith("#"):
                continue
            domain = _canonical_domain(value, path.name, line_number)
            if domain in domains:
                raise CatalogError(f"{path.name}:{line_number}: duplicate game domain {domain}")
            domains.add(domain)
            for suffix in SHARED_INFRASTRUCTURE_SUFFIXES:
                if domain == suffix or domain.endswith("." + suffix):
                    warnings.add(f"{domain}: shared infrastructure suffix .{suffix}; verify game ownership and route scope")
                    break
            if len(domains) > MAX_DOMAINS:
                raise CatalogError(f"game profile exceeds {MAX_DOMAINS} domains")
    return sorted(domains), sorted(warnings)


def render(domains: list[str]) -> bytes:
    return (HEADER + "\n".join(domains) + "\n").encode("utf-8")


def write_atomic(
    path: Path, payload: bytes, expected_parent: Path | None = None
) -> None:
    destination, expected_identity = _validated_output_path(path, expected_parent)
    with _directory_handle(destination.parent, "generated profile parent", expected_identity) as parent:
        temporary = f".{path.name}.{secrets.token_hex(8)}.tmp"
        created = False
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o644, dir_fd=parent)
            created = True
            with os.fdopen(descriptor, "wb") as output:
                output.write(payload)
                output.flush()
                os.fchmod(output.fileno(), 0o644)
                os.fsync(output.fileno())
            checked, _ = _validated_output_path(path, expected_parent)
            current = checked.parent.stat(follow_symlinks=False)
            opened = os.fstat(parent)
            if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                raise CatalogError("generated profile parent changed during publication")
            os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            created = False
            os.fsync(parent)
        finally:
            if created:
                os.unlink(temporary, dir_fd=parent)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the checked-in generated profile differs; do not write files",
    )
    args = parser.parse_args(argv)
    try:
        domains, warnings = collect_domains(GAMES_ROOT)
        expected = render(domains)
        if args.check:
            try:
                output_path, expected_identity = _validated_output_path(
                    OUTPUT, CATALOG_ROOT.parent / "profiles"
                )
                with _directory_handle(output_path.parent, "generated profile parent", expected_identity) as parent:
                    actual = _read_regular(parent, output_path.name, output_path, MAX_TOTAL_SOURCE_BYTES)
            except OSError as exc:
                raise CatalogError(f"generated profile unavailable: {exc}") from exc
            if actual != expected:
                print("games-all.domains.txt is stale; run generate_games_all.py and review the diff", file=sys.stderr)
                return 1
        else:
            write_atomic(
                OUTPUT, expected, expected_parent=CATALOG_ROOT.parent / "profiles"
            )
        for warning in warnings:
            print(f"WARNING: {warning}", file=sys.stderr)
        action = "verified" if args.check else "generated"
        print(f"{action} {OUTPUT.relative_to(CATALOG_ROOT.parent.parent)}: {len(domains)} unique domains; {len(warnings)} shared-infrastructure warnings")
        return 0
    except (CatalogError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
