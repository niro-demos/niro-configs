from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "prep-niro-demos-forks.sh"
ACTION = ROOT / ".github" / "actions" / "install" / "action.yml"
INSTALL_ACTION = (
    "niro-demos/niro-configs/.github/actions/install@"
    "8c1cc4a6a127684d1395740a74faa5f9128d3a08"
)
PROPOSE_ACTION = (
    "niro-demos/niro-configs/.github/actions/propose@"
    "5e67fd8f39949c992af0abcd6efebb1a685353cf"
)


class PrepWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def template(self, name: str) -> str:
        match = re.search(rf"{name}\(\).*?^\}}$", self.script, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, f"missing {name}")
        return match.group(0)

    def test_find_and_fix_save_findings_and_debug_logs(self) -> None:
        for name in ("find_template", "fix_template"):
            with self.subTest(template=name):
                block = self.template(name)
                self.assertIn("--include-findings=true", block)
                self.assertIn("--upload-debug-logs=true", block)

    def test_only_fix_explicitly_generates_reports(self) -> None:
        self.assertNotIn("--generate-report", self.template("find_template"))
        self.assertIn("--generate-report", self.template("fix_template"))

    def test_find_and_fix_upload_generated_reports(self) -> None:
        for name in ("find_template", "fix_template"):
            with self.subTest(template=name):
                block = self.template(name)
                run_at = block.index("- name: Run Niro")
                report_at = block.index("- name: Upload Niro penetration-test report")
                debug_at = block.index("- name: Upload debug logs")
                self.assertLess(run_at, report_at)
                self.assertLess(report_at, debug_at)

                report_step = block[report_at:debug_at]
                for expected in (
                    "if: always()",
                    "uses: actions/upload-artifact@v7",
                    "name: niro-pentest-report",
                    "path: ${{ runner.temp }}/niro-reports/**/penetration-test-report-*.pdf",
                    "if-no-files-found: ignore",
                    "retention-days: 30",
                ):
                    self.assertIn(expected, report_step)

    def test_find_and_fix_install_approved_config_before_niro(self) -> None:
        expected = f"uses: {INSTALL_ACTION}"
        for name in ("find_template", "fix_template"):
            with self.subTest(template=name):
                block = self.template(name)
                self.assertIn(expected, block)
                self.assertLess(block.index(expected), block.index("- name: Install Niro"))
                install_step = block[block.index(expected) : block.index("- name: Install Niro")]
                self.assertIn("repository: ${{ github.repository }}", install_step)
                self.assertIn("niro-dir: niro", install_step)
                self.assertIn("install-root: ${{ github.workspace }}", install_step)

    def test_find_and_fix_propose_config_after_niro(self) -> None:
        for name in ("find_template", "fix_template"):
            with self.subTest(template=name):
                block = self.template(name)
                run_at = block.index("- name: Run Niro")
                preflight_at = block.index("- name: Verify Niro config proposal credentials")
                token_at = block.index("uses: actions/create-github-app-token@v3")
                propose_at = block.index(f"uses: {PROPOSE_ACTION}")
                upload_at = block.index("- name: Upload Niro knowledge")
                self.assertLess(preflight_at, run_at)
                self.assertLess(run_at, token_at)
                self.assertLess(token_at, propose_at)
                self.assertLess(propose_at, upload_at)

                self.assertNotIn("NIRO_CONFIGS_APP_ID", block)
                self.assertNotIn("NIRO_CONFIGS_APP_PRIVATE_KEY", block)

                token_step = block[token_at:propose_at]
                self.assertIn("client-id: ${{ secrets.NIRO_APP_CLIENT_ID }}", token_step)
                self.assertNotIn("app-id:", token_step)
                self.assertIn("private-key: ${{ secrets.NIRO_APP_PRIVATE_KEY }}", token_step)

                proposal = block[propose_at:upload_at]
                self.assertIn("catalog-token: ${{ steps.niro-configs-token.outputs.token }}", proposal)
                self.assertIn("source-token: ${{ github.token }}", proposal)
                self.assertIn("archive: ${{ github.workspace }}/niro-knowledge.tar", proposal)
                self.assertIn("repository: ${{ github.repository }}", proposal)
                self.assertIn("niro-dir: niro", proposal)
                self.assertIn("source-sha: ${{ github.sha }}", proposal)
                self.assertIn("${{ github.run_id }}", proposal)

    def test_action_requires_only_generic_location_inputs(self) -> None:
        action = ACTION.read_text(encoding="utf-8")
        for name in ("repository", "niro-dir", "install-root"):
            self.assertRegex(action, rf"(?m)^  {name}:\n(?:    .*\n)*?    required: true$")
        self.assertNotIn("default:", action)
        self.assertNotRegex(action, r"(?m)^  (replace|if-missing|destination):")

    def test_action_is_pinned_to_an_immutable_commit(self) -> None:
        for action in ("install", "propose"):
            references = re.findall(
                rf"uses: niro-demos/niro-configs/\.github/actions/{action}@([^\s]+)",
                self.script,
            )
            self.assertEqual(len(references), 2)
            self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in references))

    def test_success_does_not_inherit_false_trailing_and_status(self) -> None:
        self.assertNotIn('[ "$fail" -gt 0 ] && exit 1', self.script)

    def test_workflow_rollout_checks_out_only_workflows(self) -> None:
        self.assertIn("--filter=blob:none --no-checkout", self.script)
        self.assertIn('"https://github.com/$repo.git"', self.script)
        self.assertNotIn('gh repo clone "$repo"', self.script)
        sparse_at = self.script.index("git sparse-checkout set .github/workflows")
        checkout_at = self.script.index("git checkout -q")
        replace_at = self.script.index("rm -rf .github/workflows")
        self.assertLess(sparse_at, checkout_at)
        self.assertLess(checkout_at, replace_at)


if __name__ == "__main__":
    unittest.main()
