#!/usr/bin/env python3
"""Import a completed Niro knowledge artifact and open a draft catalog PR."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Callable


CATALOG_REPOSITORY = "niro-demos/niro-configs"
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
RUN_RE = re.compile(r"/actions/runs/([0-9]+)(?:/|$)")


class ProposalError(RuntimeError):
    pass


def proposal_branch(repository: str, niro_dir: str, run_id: str) -> str:
    if (
        not REPOSITORY_RE.fullmatch(repository)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+", niro_dir)
        or not run_id.isdigit()
    ):
        raise ProposalError("invalid repository, Niro directory, or run ID")
    name = repository.split("/", 1)[1].lower()
    return f"automation/{name}-{niro_dir.lower()}-run-{run_id}"


def resolve_provenance(
    repository: str,
    source_sha: str,
    repository_info: dict,
    parent_of: Callable[[str], str | None],
    upstream_has_commit: Callable[[str, str], bool],
) -> tuple[str, str]:
    if not repository_info.get("fork"):
        return repository, source_sha
    upstream = (repository_info.get("parent") or {}).get("full_name")
    if not upstream or not REPOSITORY_RE.fullmatch(upstream):
        raise ProposalError(f"could not resolve upstream repository for {repository}")
    sha = source_sha
    for _ in range(256):
        if upstream_has_commit(upstream, sha):
            return upstream, sha
        sha = parent_of(sha)
        if not sha:
            break
    raise ProposalError(f"could not find an upstream ancestor of {source_sha}")


def command(
    arguments: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise ProposalError(f"{arguments[0]}: {detail}")
    return result


def gh_json(token: str, endpoint: str) -> dict:
    environment = {**os.environ, "GH_TOKEN": token}
    result = command(["gh", "api", endpoint], env=environment)
    return json.loads(result.stdout)


def tree_digest(root: Path) -> str | None:
    if not root.is_dir():
        return None
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update((path.stat().st_mode & 0o777).to_bytes(2, "big"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


def required_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ProposalError(f"{name} is required")
    return value


def checked_archive(value: str, workspace: Path) -> Path:
    archive = Path(value)
    if not archive.is_absolute():
        archive = workspace / archive
    archive = archive.resolve(strict=True)
    try:
        archive.relative_to(workspace)
    except ValueError as error:
        raise ProposalError("archive must be inside GITHUB_WORKSPACE") from error
    if not archive.is_file():
        raise ProposalError("archive must be a file")
    return archive


def niro_version() -> str:
    output = command(["niro", "version"]).stdout.splitlines()
    if not output:
        raise ProposalError("niro version returned no output")
    match = re.match(r"^niro\s+(\S+)", output[0])
    if not match:
        raise ProposalError(f"could not parse Niro version from {output[0]!r}")
    return match.group(1)


def main() -> int:
    catalog_token = required_environment("NIRO_CONFIG_CATALOG_TOKEN")
    source_token = required_environment("NIRO_CONFIG_SOURCE_TOKEN")
    repository = required_environment("NIRO_CONFIG_REPOSITORY")
    niro_dir = required_environment("NIRO_CONFIG_NIRO_DIR")
    source_sha = required_environment("NIRO_CONFIG_SOURCE_SHA")
    source_run = required_environment("NIRO_CONFIG_SOURCE_RUN")
    workspace = Path(required_environment("GITHUB_WORKSPACE")).resolve(strict=True)
    archive = checked_archive(required_environment("NIRO_CONFIG_ARCHIVE"), workspace)

    if not REPOSITORY_RE.fullmatch(repository):
        raise ProposalError("repository must be owner/name")
    if not SHA_RE.fullmatch(source_sha):
        raise ProposalError("source-sha must be a 40-character lowercase SHA")
    run_match = RUN_RE.search(source_run)
    expected_run_prefix = f"https://github.com/{repository}/actions/runs/"
    if not run_match or not source_run.startswith(expected_run_prefix):
        raise ProposalError("source-run must belong to the source repository")
    run_id = run_match.group(1)
    branch = proposal_branch(repository, niro_dir, run_id)

    source_info = gh_json(source_token, f"repos/{repository}")
    commit_cache: dict[str, dict] = {}

    def source_commit(sha: str) -> dict:
        if sha not in commit_cache:
            commit_cache[sha] = gh_json(source_token, f"repos/{repository}/commits/{sha}")
        return commit_cache[sha]

    source_commit(source_sha)

    def parent_of(sha: str) -> str | None:
        commit = source_commit(sha)
        parents = commit.get("parents") or []
        return parents[0].get("sha") if parents else None

    def upstream_has_commit(upstream: str, sha: str) -> bool:
        environment = {**os.environ, "GH_TOKEN": source_token}
        result = command(
            ["gh", "api", f"repos/{upstream}/commits/{sha}"],
            env=environment,
            check=False,
        )
        return result.returncode == 0

    upstream, upstream_sha = resolve_provenance(
        repository, source_sha, source_info, parent_of, upstream_has_commit
    )

    catalog_environment = {**os.environ, "GH_TOKEN": catalog_token}
    existing_prs = command(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            CATALOG_REPOSITORY,
            "--state",
            "all",
            "--head",
            branch,
            "--json",
            "url",
            "--jq",
            ".[0].url // empty",
        ],
        env=catalog_environment,
    ).stdout.strip()
    if existing_prs:
        print(f"Config proposal already exists: {existing_prs}")
        return 0

    with tempfile.TemporaryDirectory(prefix="niro-config-proposal-") as temporary:
        temporary_path = Path(temporary)
        checkout = temporary_path / "catalog"
        command(
            ["gh", "repo", "clone", CATALOG_REPOSITORY, str(checkout), "--", "--depth", "1"],
            env=catalog_environment,
        )
        target = checkout / "configs" / repository
        named_target = target / niro_dir
        before = tree_digest(named_target)
        import_arguments = [
            "python3",
            "scripts/catalog.py",
            "import",
            "--repository",
            repository,
            "--niro-dir",
            niro_dir,
            "--archive",
            str(archive),
            "--upstream",
            upstream,
            "--upstream-sha",
            upstream_sha,
            "--niro-version",
            niro_version(),
            "--source-run",
            source_run,
            "--source-run-conclusion",
            "success",
        ]
        if named_target.exists():
            import_arguments.append("--replace")
        command(import_arguments, cwd=checkout)
        after = tree_digest(named_target)
        if before == after:
            print(f"No reusable Niro config changes for {repository}; no PR opened")
            return 0

        command(
            ["python3", "scripts/catalog.py", "validate", "--repository", repository],
            cwd=checkout,
        )
        command(["git", "switch", "-c", branch], cwd=checkout)
        command(["git", "config", "user.name", "github-actions[bot]"], cwd=checkout)
        command(
            [
                "git",
                "config",
                "user.email",
                "41898282+github-actions[bot]@users.noreply.github.com",
            ],
            cwd=checkout,
        )
        relative_target = target.relative_to(checkout).as_posix()
        command(["git", "add", relative_target], cwd=checkout)
        command(["git", "diff", "--cached", "--check"], cwd=checkout)
        command(
            ["git", "commit", "-m", f"update {repository} Niro configuration"],
            cwd=checkout,
        )
        command(["gh", "auth", "setup-git"], env=catalog_environment)
        command(
            ["git", "push", "-u", "origin", branch],
            cwd=checkout,
            env=catalog_environment,
        )

        body = temporary_path / "body.md"
        body.write_text(
            "\n".join(
                [
                    "## Automated Niro configuration proposal",
                    "",
                    f"- Source repository: `{repository}`",
                    f"- Niro directory: `{niro_dir}`",
                    f"- Source run: {source_run}",
                    f"- Tested source SHA: `{source_sha}`",
                    f"- Upstream provenance: `{upstream}@{upstream_sha}`",
                    "",
                    "The knowledge artifact was imported through the catalog sanitizer. "
                    "Findings, logs, runtime state, and real credentials were excluded; "
                    "the complete saved Niro directory was replaced; catalog validation passed.",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        title = f"Update {repository} `{niro_dir}` configuration"
        pull_request = command(
            [
                "gh", "pr", "create", "--draft",
                "--repo", CATALOG_REPOSITORY,
                "--base", "main",
                "--head", branch,
                "--title", title,
                "--body-file", str(body),
            ],
            cwd=checkout,
            env=catalog_environment,
        ).stdout.strip()
        print(f"Opened config proposal: {pull_request}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProposalError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
