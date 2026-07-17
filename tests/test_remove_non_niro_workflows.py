import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "remove-non-niro-workflows.sh"


class RemoveNonNiroWorkflowsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        temp_path = Path(self.temp_dir.name)
        self.gh_log = temp_path / "gh.log"
        self.git_log = temp_path / "git.log"
        fake_bin = temp_path / "bin"
        fake_bin.mkdir()
        self.write_fake_gh(fake_bin / "gh")
        self.write_fake_git(fake_bin / "git")
        self.env = os.environ.copy()
        self.env.update(
            {
                "GH_LOG": str(self.gh_log),
                "GIT_LOG": str(self.git_log),
                "PATH": f"{fake_bin}:{self.env['PATH']}",
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_fake_gh(self, path: Path) -> None:
        path.write_text(
            """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$GH_LOG"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi

if [ "$1" = "api" ]; then
  if [ "${GH_API_EXIT:-0}" -ne 0 ]; then
    exit "$GH_API_EXIT"
  fi
  if [ "${GH_WORKFLOWS_SET:-0}" -eq 1 ]; then
    printf '%b' "${GH_WORKFLOWS:-}"
  else
    printf '.github/workflows/niro.yml\\tNiro Find\\n'
    printf '.github/workflows/build.yml\\tBuild and test\\n'
    printf '.github/workflows/fix.yaml\\tNIRO Fix\\n'
  fi
  exit 0
fi

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'main\\n'
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  printf 'https://github.com/niro-demos/example/pull/123\\n'
  exit 0
fi

exit 1
""",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def write_fake_git(self, path: Path) -> None:
        path.write_text(
            """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$GIT_LOG"

if [ "$1" = "clone" ]; then
  for argument in "$@"; do
    destination="$argument"
  done
  mkdir -p "$destination/.github/workflows"
  : > "$destination/.github/workflows/niro.yml"
  : > "$destination/.github/workflows/build.yml"
  : > "$destination/.github/workflows/fix.yaml"
  exit 0
fi

if [ "$1" = "diff" ]; then
  exit 1
fi

if [ "$1" = "commit" ]; then
  [ ! -e .github/workflows/build.yml ] || exit 1
  [ -e .github/workflows/niro.yml ] || exit 1
  [ -e .github/workflows/fix.yaml ] || exit 1
fi

exit 0
""",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_script(self, *arguments: str, **environment: str) -> subprocess.CompletedProcess:
        env = self.env.copy()
        env.update(environment)
        return subprocess.run(
            [str(SCRIPT), *arguments],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def read_log(self, path: Path) -> str:
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def test_dry_run_preserves_titles_containing_niro_case_insensitively(self) -> None:
        result = self.run_script("niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preserving 2 workflow(s)", result.stdout)
        self.assertIn("build.yml (Build and test)", result.stdout)
        self.assertNotIn("niro.yml (Niro Find)", result.stdout)
        self.assertIn("Dry run: 1 workflow file(s) would be removed", result.stdout)
        self.assertNotIn("pr create", self.read_log(self.gh_log))

    def test_apply_deletes_only_non_niro_files_and_opens_a_draft_pr(self) -> None:
        result = self.run_script("--apply", "niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Opened draft pull request", result.stdout)
        self.assertIn("commit -q -m ci: remove non-Niro workflows", self.read_log(self.git_log))
        self.assertIn("push -q -u origin niro/remove-non-niro-workflows-", self.read_log(self.git_log))
        gh_log = self.read_log(self.gh_log)
        self.assertIn("pr create --repo niro-demos/example", gh_log)
        self.assertIn("--draft", gh_log)

    def test_all_niro_workflows_are_a_successful_no_op(self) -> None:
        result = self.run_script(
            "niro-demos/example",
            GH_WORKFLOWS_SET="1",
            GH_WORKFLOWS=".github/workflows/niro.yml\\tNiro checks\\n",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No workflows need to be removed", result.stdout)
        self.assertEqual(self.read_log(self.git_log), "")

    def test_rejects_an_invalid_repository_before_calling_gh(self) -> None:
        result = self.run_script("not-a-repository")

        self.assertEqual(result.returncode, 2)
        self.assertIn("OWNER/REPOSITORY", result.stderr)
        self.assertEqual(self.read_log(self.gh_log), "")


if __name__ == "__main__":
    unittest.main()
