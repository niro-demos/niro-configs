from __future__ import annotations

import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "scripts" / "catalog.py"
INSTALLER = ROOT / ".github" / "actions" / "install" / "install.sh"


def metadata(repository: str = "niro-demos/example") -> str:
    return "\n".join(
        [
            f"repository: {repository}",
            "niro_dir: niro",
            "upstream: example/example",
            f"upstream_sha: {'a' * 40}",
            "niro_version: v1.2.3",
            "installable: true",
            "validated_at: 2026-07-12",
            "source_run: https://github.com/niro-demos/example/actions/runs/1",
            "source_run_conclusion: success",
            "",
        ]
    )


class CatalogTests(unittest.TestCase):
    def run_catalog(self, root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(CATALOG), *arguments, "--root", str(root)],
            text=True,
            capture_output=True,
            check=False,
        )

    def make_config(self, root: Path) -> Path:
        config = root / "configs" / "niro-demos" / "example"
        harness = config / "niro" / "harness"
        harness.mkdir(parents=True)
        (config / "metadata.yaml").write_text(metadata(), encoding="utf-8")
        (config / "niro" / "niro.yaml").write_text("version: 1\n", encoding="utf-8")
        (config / "niro" / "scope.yaml").write_text("targets: []\n", encoding="utf-8")
        (harness / "start.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        return config

    def test_validate_accepts_reviewable_config_and_harness(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_config(root)
            result = self.run_catalog(root, "validate")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_published_catalog_contains_only_installable_configs(self) -> None:
        for metadata_path in sorted((ROOT / "configs").glob("*/*/metadata.yaml")):
            with self.subTest(config=metadata_path.parent.relative_to(ROOT / "configs")):
                self.assertIn(
                    "installable: true",
                    metadata_path.read_text(encoding="utf-8").splitlines(),
                )

    def test_validate_accepts_explicit_non_installable_partial_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root)
            (config / "niro" / "scope.yaml").unlink()
            metadata_path = config / "metadata.yaml"
            metadata_path.write_text(
                metadata_path.read_text(encoding="utf-8").replace(
                    "installable: true", "installable: false"
                ),
                encoding="utf-8",
            )
            result = self.run_catalog(root, "validate")
            self.assertEqual(result.returncode, 0, result.stderr)

            status = self.run_catalog(
                root,
                "installable",
                "--repository",
                "niro-demos/example",
                "--niro-dir",
                "niro",
            )
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertEqual(status.stdout.strip(), "false")

    def test_validate_rejects_secret_runtime_and_symlink_content(self) -> None:
        cases = (
            ("credentials.yaml", "token: secret\n"),
            ("findings/finding.json", "{}\n"),
        )
        for relative, content in cases:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = self.make_config(root)
                unsafe = config / "niro" / relative
                unsafe.parent.mkdir(parents=True, exist_ok=True)
                unsafe.write_text(content, encoding="utf-8")
                result = self.run_catalog(root, "validate")
                self.assertNotEqual(result.returncode, 0)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root)
            (config / "niro" / "harness" / "escape").symlink_to("/tmp")
            result = self.run_catalog(root, "validate")
            self.assertNotEqual(result.returncode, 0)

    def test_installer_copies_only_approved_config_and_always_replaces_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            environment = {
                **os.environ,
                "GITHUB_WORKSPACE": str(workspace),
                "NIRO_CONFIG_REPOSITORY": "niro-demos/gitea",
                "NIRO_CONFIG_NIRO_DIR": "niro",
                "NIRO_CONFIG_INSTALL_ROOT": str(workspace),
            }
            first = subprocess.run(
                [str(INSTALLER)], env=environment, text=True, capture_output=True, check=False
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertTrue((workspace / "niro" / "harness" / "start.sh").is_file())
            self.assertFalse((workspace / "niro" / "findings").exists())

            stale = workspace / "niro" / "stale"
            stale.write_text("old\n", encoding="utf-8")
            second = subprocess.run(
                [str(INSTALLER)], env=environment, text=True, capture_output=True, check=False
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertFalse(stale.exists())

    def test_installer_rejects_niro_directory_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = {
                **os.environ,
                "GITHUB_WORKSPACE": temporary,
                "NIRO_CONFIG_REPOSITORY": "niro-demos/gitea",
                "NIRO_CONFIG_NIRO_DIR": "../escape",
                "NIRO_CONFIG_INSTALL_ROOT": temporary,
            }
            result = subprocess.run(
                [str(INSTALLER)], env=environment, text=True, capture_output=True, check=False
            )
            self.assertNotEqual(result.returncode, 0)

    def test_installer_rejects_install_root_outside_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            environment = {
                **os.environ,
                "GITHUB_WORKSPACE": temporary,
                "NIRO_CONFIG_REPOSITORY": "niro-demos/gitea",
                "NIRO_CONFIG_NIRO_DIR": "niro",
                "NIRO_CONFIG_INSTALL_ROOT": outside,
            }
            result = subprocess.run(
                [str(INSTALLER)], env=environment, text=True, capture_output=True, check=False
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inside GITHUB_WORKSPACE", result.stderr)

    def test_installer_skips_a_repository_without_an_approved_config_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = {
                **os.environ,
                "GITHUB_WORKSPACE": temporary,
                "NIRO_CONFIG_REPOSITORY": "niro-demos/not-saved-yet",
                "NIRO_CONFIG_NIRO_DIR": "niro",
                "NIRO_CONFIG_INSTALL_ROOT": temporary,
            }
            result = subprocess.run(
                [str(INSTALLER)], env=environment, text=True, capture_output=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("No approved Niro configuration", result.stdout)
            self.assertFalse((Path(temporary) / "niro").exists())

    def test_import_keeps_config_and_harness_but_drops_findings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "knowledge.tar"
            with tarfile.open(archive_path, "w") as archive:
                for name, content in (
                    ("niro/niro.yaml", b"version: 1\n"),
                    ("niro/scope.yaml", b"targets: []\n"),
                    ("niro/harness/start.sh", b"#!/bin/sh\n"),
                    ("niro/findings/TC-1/finding.json", b"{}\n"),
                    ("niro/credentials.yaml", b"token: nope\n"),
                ):
                    info = tarfile.TarInfo(name)
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))

            result = self.run_catalog(
                root,
                "import",
                "--repository",
                "niro-demos/example",
                "--niro-dir",
                "niro",
                "--archive",
                str(archive_path),
                "--upstream",
                "example/example",
                "--upstream-sha",
                "a" * 40,
                "--niro-version",
                "v1.2.3",
                "--source-run",
                "https://github.com/niro-demos/example/actions/runs/1",
                "--source-run-conclusion",
                "success",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = root / "configs" / "niro-demos" / "example" / "niro"
            self.assertTrue((config / "harness" / "start.sh").is_file())
            self.assertFalse((config / "findings").exists())
            self.assertFalse((config / "credentials.yaml").exists())

    def test_import_rejects_archive_symlinks_and_traversal(self) -> None:
        for name, member_type in (("../escape", tarfile.REGTYPE), ("niro/link", tarfile.SYMTYPE)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive_path = root / "unsafe.tar"
                with tarfile.open(archive_path, "w") as archive:
                    info = tarfile.TarInfo(name)
                    info.type = member_type
                    if member_type == tarfile.SYMTYPE:
                        info.linkname = "/tmp"
                    archive.addfile(info, io.BytesIO(b"") if member_type == tarfile.REGTYPE else None)
                result = self.run_catalog(
                    root,
                    "import",
                    "--repository",
                    "niro-demos/example",
                    "--niro-dir",
                    "niro",
                    "--archive",
                    str(archive_path),
                    "--upstream",
                    "example/example",
                    "--upstream-sha",
                    "a" * 40,
                    "--niro-version",
                    "v1.2.3",
                    "--source-run",
                    "https://github.com/niro-demos/example/actions/runs/1",
                    "--source-run-conclusion",
                    "failure",
                )
                self.assertNotEqual(result.returncode, 0)

    def test_partial_import_preserves_incomplete_knowledge_without_approving_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "partial.tar"
            with tarfile.open(archive_path, "w") as archive:
                for name, content in (
                    ("niro-staging/niro.yaml", b"version: 1\n"),
                    ("niro-staging/accepted-behaviors.yaml", b"accepted_behaviors: []\n"),
                ):
                    info = tarfile.TarInfo(name)
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))

            result = self.run_catalog(
                root,
                "import",
                "--repository",
                "niro-demos/example",
                "--niro-dir",
                "niro-staging",
                "--archive",
                str(archive_path),
                "--upstream",
                "example/example",
                "--upstream-sha",
                "a" * 40,
                "--niro-version",
                "v1.2.3",
                "--source-run",
                "https://github.com/niro-demos/example/actions/runs/1",
                "--source-run-conclusion",
                "failure",
                "--partial",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = root / "configs" / "niro-demos" / "example"
            self.assertFalse((config / "niro-staging" / "scope.yaml").exists())
            self.assertIn("niro_dir: niro-staging", (config / "metadata.yaml").read_text())
            self.assertIn("installable: false", (config / "metadata.yaml").read_text())

    def test_replace_requires_acceptance_registers_to_remain_append_only(self) -> None:
        for register, key in (
            ("accepted-behaviors.yaml", "accepted_behaviors"),
            ("accepted-coverage-gaps.yaml", "accepted_coverage_gaps"),
        ):
            with self.subTest(register=register), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = self.make_config(root)
                original = f'{key}:\n  - reason: "reviewed and retained"\n'
                (config / "niro" / register).write_text(original, encoding="utf-8")

                archive_path = root / "replacement.tar"
                with tarfile.open(archive_path, "w") as archive:
                    for name, content in (
                        ("niro/niro.yaml", b"version: 1\n"),
                        ("niro/scope.yaml", b"targets: []\n"),
                        (f"niro/{register}", f"{key}: []\n".encode()),
                    ):
                        info = tarfile.TarInfo(name)
                        info.size = len(content)
                        archive.addfile(info, io.BytesIO(content))

                result = self.run_catalog(
                    root,
                    "import",
                    "--repository",
                    "niro-demos/example",
                    "--niro-dir",
                    "niro",
                    "--archive",
                    str(archive_path),
                    "--upstream",
                    "example/example",
                    "--upstream-sha",
                    "a" * 40,
                    "--niro-version",
                    "v1.2.3",
                    "--source-run",
                    "https://github.com/niro-demos/example/actions/runs/2",
                    "--source-run-conclusion",
                    "success",
                    "--replace",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("append-only", result.stderr)
                self.assertEqual(
                    (config / "niro" / register).read_text(encoding="utf-8"), original
                )

    def test_replace_allows_appending_to_acceptance_registers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root)
            register = config / "niro" / "accepted-behaviors.yaml"
            original = 'accepted_behaviors:\n  - reason: "retained"\n'
            appended = original + '  - reason: "new"\n'
            register.write_text(original, encoding="utf-8")

            archive_path = root / "replacement.tar"
            with tarfile.open(archive_path, "w") as archive:
                for name, content in (
                    ("niro/niro.yaml", b"version: 1\n"),
                    ("niro/scope.yaml", b"targets: []\n"),
                    ("niro/accepted-behaviors.yaml", appended.encode()),
                ):
                    info = tarfile.TarInfo(name)
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))

            result = self.run_catalog(
                root,
                "import",
                "--repository",
                "niro-demos/example",
                "--niro-dir",
                "niro",
                "--archive",
                str(archive_path),
                "--upstream",
                "example/example",
                "--upstream-sha",
                "a" * 40,
                "--niro-version",
                "v1.2.3",
                "--source-run",
                "https://github.com/niro-demos/example/actions/runs/2",
                "--source-run-conclusion",
                "success",
                "--replace",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(register.read_text(encoding="utf-8"), appended)


if __name__ == "__main__":
    unittest.main()
