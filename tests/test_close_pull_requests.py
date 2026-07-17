import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "close-pull-requests.sh"


class ClosePullRequestsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        temp_path = Path(self.temp_dir.name)
        self.log = temp_path / "gh.log"
        fake_bin = temp_path / "bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$GH_LOG"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit "${GH_AUTH_EXIT:-0}"
fi

if [ "$1" = "api" ]; then
  if [ "${GH_API_EXIT:-0}" -ne 0 ]; then
    exit "$GH_API_EXIT"
  fi
  if [ "${GH_PULLS_SET:-0}" -eq 1 ]; then
    printf '%b' "${GH_PULLS:-}"
  else
    printf '12\\tFirst PR\\n34\\tSecond PR\\n'
  fi
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  if [ "${GH_FAIL_NUMBER:-}" = "$3" ]; then
    exit 1
  fi
  exit 0
fi

exit 1
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "GH_LOG": str(self.log),
                "PATH": f"{fake_bin}:{self.env['PATH']}",
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

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

    def gh_log(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def test_dry_run_lists_all_open_pull_requests_without_closing(self) -> None:
        result = self.run_script("niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#12 First PR", result.stdout)
        self.assertIn("#34 Second PR", result.stdout)
        self.assertIn("Dry run: 2 pull request(s) would be closed", result.stdout)
        self.assertNotIn("pr close", self.gh_log())
        self.assertIn(
            "repos/niro-demos/example/pulls?state=open&per_page=100",
            self.gh_log(),
        )

    def test_apply_closes_every_open_pull_request(self) -> None:
        result = self.run_script("--apply", "niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Closed 2 pull request(s); 0 failed", result.stdout)
        self.assertIn("pr close 12 --repo niro-demos/example", self.gh_log())
        self.assertIn("pr close 34 --repo niro-demos/example", self.gh_log())

    def test_apply_continues_after_a_close_failure(self) -> None:
        result = self.run_script(
            "--apply",
            "niro-demos/example",
            GH_FAIL_NUMBER="12",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to close #12", result.stderr)
        self.assertIn("pr close 34 --repo niro-demos/example", self.gh_log())
        self.assertIn("Closed 1 pull request(s); 1 failed", result.stdout)

    def test_empty_repository_is_a_successful_no_op(self) -> None:
        result = self.run_script(
            "niro-demos/example",
            GH_PULLS_SET="1",
            GH_PULLS="",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No open pull requests", result.stdout)
        self.assertNotIn("pr close", self.gh_log())

    def test_rejects_an_invalid_repository_before_calling_gh(self) -> None:
        result = self.run_script("not-a-repository")

        self.assertEqual(result.returncode, 2)
        self.assertIn("OWNER/REPOSITORY", result.stderr)
        self.assertEqual(self.gh_log(), "")


if __name__ == "__main__":
    unittest.main()
