#!/usr/bin/env python3
"""Validate and import reviewed, repository-specific Niro configurations."""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile


REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MAX_FILE_SIZE = 1024 * 1024
ROOT_FILES = {
    "README.md",
    "accepted-behaviors.yaml",
    "accepted-behaviors.yaml.example",
    "accepted-coverage-gaps.yaml",
    "accepted-coverage-gaps.yaml.example",
    "credentials.yaml.example",
    "fixtures.yaml.example",
    "niro.yaml",
    "scope.yaml",
}
BANNED_DIRS = {
    ".git",
    "cache",
    "debug-logs",
    "findings",
    "logs",
    "node_modules",
    "run",
    "runs",
    "runtime",
    "state",
    "tmp",
}
BANNED_FILES = {"credentials.yaml", "fixtures.yaml", ".ds_store"}
BANNED_SUFFIXES = {
    ".7z",
    ".bak",
    ".gz",
    ".key",
    ".log",
    ".p12",
    ".pem",
    ".tar",
    ".tgz",
    ".zip",
}
REQUIRED_METADATA = {
    "installable",
    "niro_dir",
    "repository",
    "upstream",
    "upstream_sha",
    "niro_version",
    "validated_at",
    "source_run",
    "source_run_conclusion",
}


class CatalogError(RuntimeError):
    pass


def checked_repository(value: str) -> str:
    if not REPOSITORY_RE.fullmatch(value):
        raise CatalogError(f"invalid repository name: {value!r}")
    return value


def checked_niro_dir(value: str) -> str:
    if value in {".", "..", "metadata"} or not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise CatalogError(f"invalid Niro directory name: {value!r}")
    return value


def metadata_path(config: Path, niro_dir: str) -> Path:
    return config / "metadata" / f"{checked_niro_dir(niro_dir)}.yaml"


def parse_metadata(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([a-z_]+):\s*(.*?)\s*", line)
        if not match:
            raise CatalogError(f"{path}: metadata must contain simple key/value pairs")
        values[match.group(1)] = match.group(2).strip('"')
    missing = REQUIRED_METADATA - values.keys()
    if missing:
        raise CatalogError(f"{path}: missing metadata: {', '.join(sorted(missing))}")
    return values


def validate_file(path: Path, relative: PurePosixPath) -> None:
    lowered_parts = {part.lower() for part in relative.parts}
    if lowered_parts & BANNED_DIRS:
        raise CatalogError(f"runtime or result directory is not allowed: {relative}")

    name = relative.name.lower()
    if name in BANNED_FILES or name.startswith(".env"):
        raise CatalogError(f"secret-prone file is not allowed: {relative}")
    if any(name.endswith(suffix) for suffix in BANNED_SUFFIXES):
        raise CatalogError(f"archive, key, or log file is not allowed: {relative}")
    if relative.parts[0] != "harness" and str(relative) not in ROOT_FILES:
        raise CatalogError(f"unexpected Niro config file: {relative}")
    if path.stat().st_size > MAX_FILE_SIZE:
        raise CatalogError(f"file exceeds {MAX_FILE_SIZE} bytes: {relative}")
    if b"\0" in path.read_bytes():
        raise CatalogError(f"binary file is not allowed: {relative}")


def validate_configuration(root: Path, repository: str, niro_dir: str) -> dict[str, str]:
    repository = checked_repository(repository)
    niro_dir = checked_niro_dir(niro_dir)
    config = root / "configs" / repository
    selected_metadata = metadata_path(config, niro_dir)

    if not selected_metadata.is_file():
        raise CatalogError(f"no approved configuration for {repository}/{niro_dir}")
    metadata = parse_metadata(selected_metadata)
    niro = config / niro_dir
    if not niro.is_dir():
        raise CatalogError(f"{repository}: configured Niro directory does not exist: {niro_dir}")
    if metadata["repository"] != repository:
        raise CatalogError(f"{selected_metadata}: repository does not match its directory")
    if metadata["niro_dir"] != niro_dir:
        raise CatalogError(f"{selected_metadata}: niro_dir does not match its filename")
    checked_repository(metadata["upstream"])
    if not SHA_RE.fullmatch(metadata["upstream_sha"]):
        raise CatalogError(
            f"{selected_metadata}: upstream_sha must be a 40-character lowercase SHA"
        )
    try:
        dt.date.fromisoformat(metadata["validated_at"])
    except ValueError as error:
        raise CatalogError(f"{selected_metadata}: validated_at must be YYYY-MM-DD") from error
    if not metadata["niro_version"] or not metadata["source_run"].startswith("https://github.com/"):
        raise CatalogError(
            f"{selected_metadata}: niro_version and GitHub source_run are required"
        )
    if metadata["installable"] not in {"true", "false"}:
        raise CatalogError(f"{selected_metadata}: installable must be true or false")
    if metadata["source_run_conclusion"] not in {
        "success",
        "failure",
        "cancelled",
        "timed_out",
    }:
        raise CatalogError(f"{selected_metadata}: unsupported source_run_conclusion")
    if not (niro / "niro.yaml").is_file():
        raise CatalogError(f"{repository}/{niro_dir}: niro.yaml is required")
    if metadata["installable"] == "true" and not (niro / "scope.yaml").is_file():
        raise CatalogError(f"{repository}/{niro_dir}: installable config requires scope.yaml")

    for path in niro.rglob("*"):
        if path.is_symlink():
            raise CatalogError(f"symlink is not allowed: {path.relative_to(config)}")
        if path.is_file():
            relative = PurePosixPath(path.relative_to(niro).as_posix())
            validate_file(path, relative)
    return metadata


def validate_repository(root: Path, repository: str) -> None:
    repository = checked_repository(repository)
    config = root / "configs" / repository
    metadata_dir = config / "metadata"
    if not metadata_dir.is_dir() or metadata_dir.is_symlink():
        raise CatalogError(f"no approved configurations for {repository}")

    niro_dirs: set[str] = set()
    for path in sorted(metadata_dir.iterdir()):
        if path.is_symlink() or not path.is_file() or path.suffix != ".yaml":
            raise CatalogError(f"unexpected metadata entry: {path.relative_to(config)}")
        niro_dir = checked_niro_dir(path.stem)
        if path.name != f"{niro_dir}.yaml":
            raise CatalogError(f"metadata filename does not match Niro directory: {path.name}")
        validate_configuration(root, repository, niro_dir)
        niro_dirs.add(niro_dir)

    if not niro_dirs:
        raise CatalogError(f"no approved configurations for {repository}")
    for path in sorted(config.iterdir()):
        if path.name == "metadata":
            continue
        if path.name not in niro_dirs or not path.is_dir() or path.is_symlink():
            raise CatalogError(f"unexpected catalog entry: {path.relative_to(config)}")


def validate_catalog(root: Path, repository: str | None) -> None:
    if repository:
        validate_repository(root, repository)
        return

    configs = root / "configs"
    found = False
    if configs.is_dir():
        for owner in sorted(configs.iterdir()):
            if not owner.is_dir():
                raise CatalogError(f"unexpected file in configs/: {owner.name}")
            for repo in sorted(owner.iterdir()):
                if repo.is_dir():
                    found = True
                    validate_repository(root, f"{owner.name}/{repo.name}")
                else:
                    raise CatalogError(f"unexpected file in configs/{owner.name}: {repo.name}")
    if not found:
        raise CatalogError("catalog contains no configurations")


def safe_member_path(member: tarfile.TarInfo) -> PurePosixPath:
    value = member.name.removeprefix("./")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise CatalogError(f"unsafe archive path: {member.name}")
    if not (member.isfile() or member.isdir()):
        raise CatalogError(f"archive links and special files are not allowed: {member.name}")
    return path


def write_metadata(path: Path, args: argparse.Namespace) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                f"repository: {args.repository}",
                f"niro_dir: {args.niro_dir}",
                f"upstream: {args.upstream}",
                f"upstream_sha: {args.upstream_sha}",
                f"niro_version: {args.niro_version}",
                f"installable: {'false' if args.partial else 'true'}",
                f"validated_at: {dt.date.today().isoformat()}",
                f"source_run: {args.source_run}",
                f"source_run_conclusion: {args.source_run_conclusion}",
                "",
            ]
        ),
        encoding="utf-8",
    )


def import_archive(root: Path, args: argparse.Namespace) -> None:
    checked_repository(args.repository)
    checked_repository(args.upstream)
    checked_niro_dir(args.niro_dir)
    if not SHA_RE.fullmatch(args.upstream_sha):
        raise CatalogError("upstream-sha must be a 40-character lowercase SHA")
    if not args.source_run.startswith("https://github.com/"):
        raise CatalogError("source-run must be a GitHub URL")

    config = root / "configs" / args.repository
    target = config / args.niro_dir
    target_metadata = metadata_path(config, args.niro_dir)
    if (target.exists() or target_metadata.exists()) and not args.replace:
        raise CatalogError(
            f"{args.repository}/{args.niro_dir} already exists; pass --replace to update it"
        )

    with tempfile.TemporaryDirectory(prefix="niro-config-import-") as temporary:
        temp_root = Path(temporary)
        staged_config = temp_root / "configs" / args.repository
        niro = staged_config / args.niro_dir
        niro.mkdir(parents=True)

        with tarfile.open(args.archive, mode="r:*") as archive:
            for member in archive.getmembers():
                path = safe_member_path(member)
                if not path.parts or path.parts[0] != args.niro_dir or len(path.parts) == 1:
                    continue
                relative = PurePosixPath(*path.parts[1:])
                if member.isdir():
                    continue
                lowered_parts = {part.lower() for part in relative.parts}
                lowered_name = relative.name.lower()
                if (
                    lowered_parts & BANNED_DIRS
                    or lowered_name in BANNED_FILES
                    or lowered_name.startswith(".env")
                    or any(lowered_name.endswith(suffix) for suffix in BANNED_SUFFIXES)
                ):
                    continue
                output = niro.joinpath(*relative.parts)
                output.parent.mkdir(parents=True, exist_ok=True)
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise CatalogError(f"could not read archive member: {member.name}")
                output.write_bytes(extracted.read())
                output.chmod(member.mode & 0o755)

        staged_metadata = metadata_path(staged_config, args.niro_dir)
        write_metadata(staged_metadata, args)
        validate_repository(temp_root, args.repository)

        config.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise CatalogError(f"refusing to replace symlink: {target}")
        if target_metadata.is_symlink() or target_metadata.parent.is_symlink():
            raise CatalogError(f"refusing to replace symlink: {target_metadata}")
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(niro, target)
        target_metadata.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staged_metadata, target_metadata)

    print(f"Imported candidate configuration for {args.repository}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", choices=("validate", "import", "installable"))
    result.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    result.add_argument("--repository")
    result.add_argument("--niro-dir")
    result.add_argument("--archive", type=Path)
    result.add_argument("--upstream")
    result.add_argument("--upstream-sha")
    result.add_argument("--niro-version")
    result.add_argument("--source-run")
    result.add_argument("--source-run-conclusion")
    result.add_argument("--partial", action="store_true")
    result.add_argument("--replace", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "validate":
            validate_catalog(args.root.resolve(), args.repository)
        elif args.command == "installable":
            if not args.repository or not args.niro_dir:
                raise CatalogError("installable requires: repository, niro-dir")
            metadata = validate_configuration(
                args.root.resolve(), args.repository, args.niro_dir
            )
            print(metadata["installable"])
        else:
            required = (
                "repository",
                "niro_dir",
                "archive",
                "upstream",
                "upstream_sha",
                "niro_version",
                "source_run",
                "source_run_conclusion",
            )
            missing = [name.replace("_", "-") for name in required if not getattr(args, name)]
            if missing:
                raise CatalogError(f"import requires: {', '.join(missing)}")
            import_archive(args.root.resolve(), args)
    except (CatalogError, OSError, tarfile.TarError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
