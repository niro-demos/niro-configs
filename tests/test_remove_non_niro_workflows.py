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
        self.log = temp_path / "gh.log"
        fake_bin = temp_path / "bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$GH_LOG"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "--paginate" ]; then
  if [ "${GH_API_EXIT:-0}" -ne 0 ]; then
    exit "$GH_API_EXIT"
  fi
  if [ "${GH_RUNS_SET:-0}" -eq 1 ]; then
    printf '%b' "${GH_RUNS:-}"
  else
    printf '101\\tNiro Find (codex)\\tNiro Find (Codex)\\n'
    printf '102\\tFix clustering test\\tKeycloak CI\\n'
    printf '103\\tNIRO FIX (claude)\\tNiro Fix (Claude)\\n'
    printf '104\\tAdd Niro Codex find workflow\\tCodeQL\\n'
  fi
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
  if [[ "$4" = */"${GH_FAIL_RUN_ID:-never}" ]]; then
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

    def test_dry_run_preserves_only_niro_find_and_fix_titles(self) -> None:
        result = self.run_script("niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preserving 2 run(s)", result.stdout)
        self.assertIn("102: Fix clustering test", result.stdout)
        self.assertIn("104: Add Niro Codex find workflow", result.stdout)
        self.assertNotIn("101: Niro Find (codex)", result.stdout)
        self.assertNotIn("103: NIRO FIX (claude)", result.stdout)
        self.assertIn("Dry run: 2 workflow run(s) would be permanently deleted", result.stdout)
        self.assertNotIn("--method DELETE", self.gh_log())

    def test_apply_deletes_every_non_matching_run(self) -> None:
        result = self.run_script("--apply", "niro-demos/example")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Deleted 2 workflow run(s); 0 failed", result.stdout)
        self.assertIn(
            "api --method DELETE repos/niro-demos/example/actions/runs/102 --silent",
            self.gh_log(),
        )
        self.assertIn(
            "api --method DELETE repos/niro-demos/example/actions/runs/104 --silent",
            self.gh_log(),
        )
        self.assertNotIn("actions/runs/101 --silent", self.gh_log())
        self.assertNotIn("actions/runs/103 --silent", self.gh_log())

    def test_apply_continues_after_a_delete_failure(self) -> None:
        result = self.run_script(
            "--apply",
            "niro-demos/example",
            GH_FAIL_RUN_ID="102",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to delete workflow run 102", result.stderr)
        self.assertIn("actions/runs/104 --silent", self.gh_log())
        self.assertIn("Deleted 1 workflow run(s); 1 failed", result.stdout)

    def test_empty_actions_history_is_a_successful_no_op(self) -> None:
        result = self.run_script(
            "niro-demos/example",
            GH_RUNS_SET="1",
            GH_RUNS="",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No GitHub Actions workflow runs", result.stdout)
        self.assertNotIn("--method DELETE", self.gh_log())

    def test_rejects_an_invalid_repository_before_calling_gh(self) -> None:
        result = self.run_script("not-a-repository")

        self.assertEqual(result.returncode, 2)
        self.assertIn("OWNER/REPOSITORY", result.stderr)
        self.assertEqual(self.gh_log(), "")


if __name__ == "__main__":
    unittest.main()
