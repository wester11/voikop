from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_games_all as generator
from generate_games_all import CatalogError, collect_domains, render, write_atomic


class GameProfileGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write(self, name: str, contents: str) -> None:
        (self.root / name).write_text(contents, encoding="utf-8")

    def collect(self) -> tuple[list[str], list[str]]:
        return collect_domains(self.root)

    @staticmethod
    def snapshot_tree(root: Path) -> list[tuple[str, int, int, int, bytes | None]]:
        snapshot = []
        for path in sorted(root.rglob("*")):
            stat = path.stat()
            snapshot.append(
                (
                    path.relative_to(root).as_posix(),
                    stat.st_size,
                    stat.st_mtime_ns,
                    stat.st_mode,
                    path.read_bytes() if path.is_file() else None,
                )
            )
        return snapshot

    def test_repository_union_has_339_and_does_not_drop_existing_entries(self) -> None:
        catalog = Path(__file__).resolve().parent
        old_profile = catalog.parent / "profiles" / "games-all.domains.txt"
        old_entries = {
            line.strip().lower()
            for line in old_profile.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        generated, _ = collect_domains(catalog / "games")
        self.assertEqual(339, len(generated))
        self.assertEqual(old_entries, set(generated))

        profile_registry = json.loads(
            (catalog.parent / "profiles" / "profiles.json").read_text(encoding="utf-8")
        )
        games_profile = next(item for item in profile_registry["profiles"] if item["id"] == "games-all")
        self.assertIs(games_profile["default_enabled"], False)

    def test_generation_is_deterministic_and_sorted(self) -> None:
        self.write("zeta.domains.txt", "z-game.com\na-game.com\n")
        first, _ = self.collect()
        second, _ = self.collect()
        self.assertEqual(["a-game.com", "z-game.com"], first)
        self.assertEqual(render(first), render(second))

    def test_normalizes_ascii_case_and_surrounding_whitespace(self) -> None:
        self.write("game.domains.txt", "  EXAMPLE.COM  \n")
        self.assertEqual(["example.com"], self.collect()[0])

    def test_idn_policy_accepts_canonical_alabel_and_rejects_unicode_ulabel(self) -> None:
        self.write("idn.domains.txt", "xn--bcher-kva.de\n")
        self.assertEqual(["xn--bcher-kva.de"], self.collect()[0])
        self.write("idn.domains.txt", "пример.рф\n")
        with self.assertRaisesRegex(CatalogError, "Unicode IDN"):
            self.collect()
        self.write("idn.domains.txt", "game.xn--p1ai\n")
        with self.assertRaisesRegex(CatalogError, "IDN public suffixes are unsupported"):
            self.collect()

    def test_duplicate_within_or_across_files_fails_closed(self) -> None:
        self.write("one.domains.txt", "duplicate-game.com\nduplicate-game.com\n")
        with self.assertRaisesRegex(CatalogError, "duplicate game domain"):
            self.collect()
        (self.root / "one.domains.txt").write_text("duplicate-game.com\n", encoding="utf-8")
        self.write("two.domains.txt", "duplicate-game.com\n")
        with self.assertRaisesRegex(CatalogError, "duplicate game domain"):
            self.collect()

    def test_private_reserved_and_public_ip_literals_are_rejected(self) -> None:
        for address in ("192.168.1.2", "203.0.113.10", "2001:db8::1"):
            with self.subTest(address=address):
                self.write("game.domains.txt", address + "\n")
                with self.assertRaisesRegex(CatalogError, "IP literals"):
                    self.collect()

    def test_oversized_domain_and_source_file_are_rejected(self) -> None:
        self.write("game.domains.txt", "a" * 254 + ".com\n")
        with self.assertRaisesRegex(CatalogError, "exceeds 253 bytes"):
            self.collect()
        (self.root / "game.domains.txt").write_text("x" * (1_048_577), encoding="utf-8")
        with self.assertRaisesRegex(CatalogError, "source exceeds"):
            self.collect()

    def test_broad_provider_suffix_is_rejected_but_specific_host_warns(self) -> None:
        self.write("game.domains.txt", "cloudfront.net\n")
        with self.assertRaisesRegex(CatalogError, "provider-wide shared suffix"):
            self.collect()
        self.write("game.domains.txt", "specific-game.cloudfront.net\n")
        domains, warnings = self.collect()
        self.assertEqual(["specific-game.cloudfront.net"], domains)
        self.assertEqual(1, len(warnings))
        self.assertIn("shared infrastructure suffix", warnings[0])

    def test_invalid_suffix_wildcard_and_control_characters_are_rejected(self) -> None:
        for invalid in ("game.c", "game.localhost", "*.game.example", "game..example", "game.example\x00"):
            with self.subTest(invalid=repr(invalid)):
                self.write("game.domains.txt", invalid + "\n")
                with self.assertRaises(CatalogError):
                    self.collect()

    def test_utf8_errors_are_reported_without_replacement(self) -> None:
        (self.root / "game.domains.txt").write_bytes(b"game.example.com\n\xff\n")
        with self.assertRaisesRegex(CatalogError, "not valid UTF-8"):
            self.collect()

    def test_symbolic_link_source_fails_closed(self) -> None:
        source_dir = self.root / "source"
        source_dir.mkdir()
        outside = self.root / "outside.domains.txt"
        outside.write_text("game.example.com\n", encoding="utf-8")
        link = source_dir / "linked.domains.txt"
        try:
            link.symlink_to(outside)
        except (OSError, NotImplementedError):
            # Windows may deny symlink creation for non-elevated users. Keep
            # this guard covered by marking the catalog path as a symlink.
            link.write_text("game.example.com\n", encoding="utf-8")
            with patch.object(
                Path,
                "is_symlink",
                autospec=True,
                side_effect=lambda path: path.name == "linked.domains.txt",
            ):
                with self.assertRaisesRegex(CatalogError, "symbolic-link sources"):
                    collect_domains(source_dir)
        else:
            with self.assertRaisesRegex(CatalogError, "symbolic-link sources"):
                collect_domains(source_dir)

    def test_symbolic_link_games_root_fails_before_reading_external_tree(self) -> None:
        external = self.root / "external-games"
        external.mkdir()
        (external / "outside.domains.txt").write_text(
            "outside-game.example\n", encoding="utf-8"
        )
        linked_root = self.root / "games-link"
        before = self.snapshot_tree(external)
        try:
            linked_root.symlink_to(external, target_is_directory=True)
        except (OSError, NotImplementedError):
            linked_root.mkdir()
            with patch.object(
                Path,
                "is_symlink",
                autospec=True,
                side_effect=lambda path: path == linked_root,
            ):
                with self.assertRaisesRegex(CatalogError, "symbolic-link directories"):
                    collect_domains(linked_root)
        else:
            with self.assertRaisesRegex(CatalogError, "symbolic-link directories"):
                collect_domains(linked_root)
        self.assertEqual(before, self.snapshot_tree(external))

    def test_source_swapped_to_symlink_before_open_is_not_read(self) -> None:
        source = self.root / "game.domains.txt"
        source.write_text("safe-game.com\n", encoding="utf-8")
        external = self.root / "outside.txt"
        external.write_bytes(b"DO NOT READ THIS EXTERNAL CONTENT\n")
        real_open = os.open

        def swap_then_open(name, flags, *args, **kwargs):
            if name == source.name and "dir_fd" in kwargs:
                source.unlink()
                source.symlink_to(external)
            return real_open(name, flags, *args, **kwargs)

        with patch("generate_games_all.os.open", side_effect=swap_then_open):
            with self.assertRaisesRegex(CatalogError, "source changed before reading"):
                self.collect()
        self.assertEqual(b"DO NOT READ THIS EXTERNAL CONTENT\n", external.read_bytes())

    def test_real_source_directory_substitution_before_open_is_rejected(self) -> None:
        source = self.root / "source"
        source.mkdir()
        (source / "game.domains.txt").write_bytes(b"original-game.com\n")
        original = self.root / "source-original"
        real_open = os.open

        def swap_then_open(name, flags, *args, **kwargs):
            if name == "source" and flags & os.O_DIRECTORY:
                source.rename(original)
                source.mkdir()
                (source / "game.domains.txt").write_bytes(b"outside-game.com\n")
            return real_open(name, flags, *args, **kwargs)

        with patch("generate_games_all.os.open", side_effect=swap_then_open):
            with self.assertRaisesRegex(CatalogError, "directory changed while opening"):
                collect_domains(source)
        self.assertEqual(b"original-game.com\n", (original / "game.domains.txt").read_bytes())

    def test_real_output_directory_substitution_before_open_has_no_publication(self) -> None:
        parent = self.root / "profiles"
        parent.mkdir()
        (parent / "games-all.domains.txt").write_bytes(b"original\n")
        original = self.root / "profiles-original"
        real_open = os.open

        def swap_then_open(name, flags, *args, **kwargs):
            if name == "profiles" and flags & os.O_DIRECTORY:
                parent.rename(original)
                parent.mkdir()
                (parent / "games-all.domains.txt").write_bytes(b"replacement-sentinel\n")
            return real_open(name, flags, *args, **kwargs)

        with patch("generate_games_all.os.open", side_effect=swap_then_open):
            with self.assertRaisesRegex(CatalogError, "directory changed while opening"):
                write_atomic(parent / "games-all.domains.txt", b"untrusted-publication\n")
        self.assertEqual(b"original\n", (original / "games-all.domains.txt").read_bytes())
        self.assertEqual(b"replacement-sentinel\n", (parent / "games-all.domains.txt").read_bytes())
        self.assertEqual(["games-all.domains.txt"], [p.name for p in parent.iterdir()])

    def test_output_swap_after_validation_before_directory_context_is_rejected(self) -> None:
        parent = self.root / "profiles"
        parent.mkdir()
        (parent / "games-all.domains.txt").write_bytes(b"original\n")
        original = self.root / "profiles-original"
        real_handle = generator._directory_handle

        def swap_then_handle(path, label, *args, **kwargs):
            parent.rename(original)
            parent.mkdir()
            (parent / "games-all.domains.txt").write_bytes(b"replacement-sentinel\n")
            return real_handle(path, label, *args, **kwargs)

        with patch("generate_games_all._directory_handle", side_effect=swap_then_handle):
            with self.assertRaisesRegex(CatalogError, "validated directory identity changed"):
                write_atomic(parent / "games-all.domains.txt", b"untrusted-publication\n")
        self.assertEqual(b"original\n", (original / "games-all.domains.txt").read_bytes())
        self.assertEqual(b"replacement-sentinel\n", (parent / "games-all.domains.txt").read_bytes())
        self.assertEqual(["games-all.domains.txt"], [p.name for p in parent.iterdir()])

    def test_output_parent_swap_during_temp_creation_has_no_external_mutation(self) -> None:
        parent = self.root / "profiles"
        parent.mkdir()
        (parent / "games-all.domains.txt").write_bytes(b"original\n")
        original = self.root / "profiles-original"
        external = self.root / "external"
        external.mkdir()
        (external / "games-all.domains.txt").write_bytes(b"external-sentinel\n")
        before = self.snapshot_tree(external)
        real_open = os.open

        def swap_then_open(name, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                parent.rename(original)
                parent.symlink_to(external, target_is_directory=True)
            return real_open(name, flags, *args, **kwargs)

        with patch("generate_games_all.os.open", side_effect=swap_then_open):
            with self.assertRaisesRegex(CatalogError, "symbolic-link directories"):
                write_atomic(parent / "games-all.domains.txt", b"replacement\n")
        self.assertEqual(before, self.snapshot_tree(external))
        self.assertEqual(["games-all.domains.txt"], sorted(p.name for p in original.iterdir()))
        self.assertEqual(b"original\n", (original / "games-all.domains.txt").read_bytes())

    def test_late_destination_symlink_is_replaced_without_following_target(self) -> None:
        parent = self.root / "profiles"
        parent.mkdir()
        destination = parent / "games-all.domains.txt"
        external = self.root / "external.txt"
        external.write_bytes(b"external-sentinel\n")
        real_replace = os.replace

        def swap_then_replace(source, target, **kwargs):
            destination.symlink_to(external)
            return real_replace(source, target, **kwargs)

        with patch("generate_games_all.os.replace", side_effect=swap_then_replace):
            write_atomic(destination, b"verified-profile\n")
        self.assertFalse(destination.is_symlink())
        self.assertEqual(b"verified-profile\n", destination.read_bytes())
        self.assertEqual(b"external-sentinel\n", external.read_bytes())

    def test_symbolic_link_output_parent_fails_without_external_mutation(self) -> None:
        external = self.root / "external-output"
        external.mkdir()
        sentinel = external / "games-all.domains.txt"
        sentinel.write_bytes(b"keep-existing-output\n")
        unrelated = external / "unrelated.txt"
        unrelated.write_bytes(b"keep-unrelated-file\n")
        before = self.snapshot_tree(external)
        linked_parent = self.root / "profiles-link"
        try:
            linked_parent.symlink_to(external, target_is_directory=True)
        except (OSError, NotImplementedError):
            linked_parent.mkdir()
            with patch.object(
                Path,
                "is_symlink",
                autospec=True,
                side_effect=lambda path: path == linked_parent,
            ):
                with self.assertRaisesRegex(CatalogError, "symbolic-link directories"):
                    write_atomic(linked_parent / sentinel.name, b"untrusted replacement\n")
        else:
            with self.assertRaisesRegex(CatalogError, "symbolic-link directories"):
                write_atomic(linked_parent / sentinel.name, b"untrusted replacement\n")
        self.assertEqual(before, self.snapshot_tree(external))


if __name__ == "__main__":
    unittest.main()
