from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "prep-niro-demos-forks.sh"
INSTALL_ACTION = (
    "niro-demos/niro-configs/.github/actions/install@"
    "971b072f46bdb1faac04bb22c62d2abaf93c4af1"
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

    def test_find_and_fix_install_approved_config_before_niro(self) -> None:
        expected = f"uses: {INSTALL_ACTION}"
        for name in ("find_template", "fix_template"):
            with self.subTest(template=name):
                block = self.template(name)
                self.assertIn(expected, block)
                self.assertLess(block.index(expected), block.index("- name: Install Niro"))

    def test_action_is_pinned_to_an_immutable_commit(self) -> None:
        references = re.findall(
            r"uses: niro-demos/niro-configs/\.github/actions/install@([^\s]+)",
            self.script,
        )
        self.assertEqual(len(references), 2)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in references))

    def test_success_does_not_inherit_false_trailing_and_status(self) -> None:
        self.assertNotIn('[ "$fail" -gt 0 ] && exit 1', self.script)


if __name__ == "__main__":
    unittest.main()
