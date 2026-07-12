from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github" / "actions" / "propose" / "action.yml"
PROPOSER = ROOT / "scripts" / "propose.py"


def load_proposer():
    spec = importlib.util.spec_from_file_location("propose", PROPOSER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load propose.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProposeTests(unittest.TestCase):
    def test_action_requires_separate_catalog_and_source_tokens(self) -> None:
        action = ACTION.read_text(encoding="utf-8")
        for name in (
            "catalog-token",
            "source-token",
            "archive",
            "repository",
            "niro-dir",
            "source-sha",
            "source-run",
        ):
            self.assertRegex(action, rf"(?m)^  {name}:\n(?:    .*\n)*?    required: true$")

    def test_branch_name_is_stable_and_contains_no_untrusted_path(self) -> None:
        proposer = load_proposer()
        self.assertEqual(
            proposer.proposal_branch("niro-demos/Sieve", "29209296603"),
            "automation/sieve-run-29209296603",
        )

    def test_resolve_provenance_finds_first_commit_owned_by_upstream(self) -> None:
        proposer = load_proposer()
        parents = {"workflow": "fix", "fix": "upstream", "upstream": None}
        checked = []

        def parent_of(sha: str):
            return parents[sha]

        def upstream_has_commit(repository: str, sha: str) -> bool:
            checked.append((repository, sha))
            return sha == "upstream"

        upstream, sha = proposer.resolve_provenance(
            "niro-demos/fork",
            "workflow",
            {"fork": True, "parent": {"full_name": "upstream/project"}},
            parent_of,
            upstream_has_commit,
        )
        self.assertEqual((upstream, sha), ("upstream/project", "upstream"))
        self.assertEqual(
            checked,
            [
                ("upstream/project", "workflow"),
                ("upstream/project", "fix"),
                ("upstream/project", "upstream"),
            ],
        )

    def test_non_fork_provenance_uses_the_tested_repository_commit(self) -> None:
        proposer = load_proposer()
        self.assertEqual(
            proposer.resolve_provenance(
                "niro-demos/sieve",
                "abc123",
                {"fork": False},
                lambda _: None,
                lambda _repository, _sha: False,
            ),
            ("niro-demos/sieve", "abc123"),
        )

    def test_proposer_opens_a_draft_pull_request(self) -> None:
        source = PROPOSER.read_text(encoding="utf-8")
        self.assertIn('"pr", "create", "--draft"', source)


if __name__ == "__main__":
    unittest.main()
