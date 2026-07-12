# Niro Config Catalog Guidance

Read `README.md` completely before making changes. It is the shared contract for
humans and agents and defines the catalog lifecycle, installer interface, and
safety boundary.

## Required practices

- Publish only complete configurations with `installable: true`.
- Import knowledge with `scripts/catalog.py`; never copy an artifact wholesale.
- Never commit real credentials or fixtures, findings, logs, archives, runtime
  state, caches, binary files, private keys, or symlinks.
- Preserve every existing accepted-behavior and accepted-coverage-gap entry
  unless a human explicitly requests its removal.
- Keep metadata provenance exact: repository, Niro directory, upstream commit,
  Niro version, source run, conclusion, and validation date.
- Treat `repository`, `niro-dir`, and absolute `install-root` as the installer's
  required public contract. Keep install destinations inside `GITHUB_WORKSPACE`.
- Pin generated workflows to an immutable installer commit. When the installer
  or catalog changes, commit that implementation first and update the workflow
  pin in a follow-up commit.
- For bugs, add a regression test and confirm it fails before applying the fix.
- Always work on a branch and open a PR. Never push directly to `main`.

## Required validation

Run all of the following before publishing:

```bash
python3 -m unittest discover -s tests -v
python3 scripts/catalog.py validate
bash -n .github/actions/install/install.sh scripts/prep-niro-demos-forks.sh
git diff --check
```

CI validates changes but never merges them. Human review remains required.
