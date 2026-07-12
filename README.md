# Niro demo configurations

This repository is the reviewed source of reusable `niro/` configuration for
repositories in the [`niro-demos`](https://github.com/niro-demos) organization.
It avoids paying the setup cost on every pentest while keeping model-generated
configuration behind a pull-request review boundary.

## Lifecycle

1. A demo workflow installs the approved config before `niro find` or
   `niro fix`.
2. Niro uploads `niro-knowledge.tar` after the run.
3. A trusted operator imports that artifact on a branch.
4. Validation and human review gate the config before it reaches `main`.

The testing agent never receives credentials that can write to this repository.

## Layout

```text
configs/<owner>/<repo>/
  metadata.yaml
  niro/
.github/actions/install/
scripts/
```

The catalog keeps declarative Niro files and reviewed harness source. It rejects
findings, logs, runtime state, real credential/fixture files, archives, binary
files, and symlinks. Example credential and fixture templates are allowed because
they contain public demo seed data rather than live secrets.

## Install in a workflow

Pin the action to an immutable commit:

```yaml
- name: Install approved Niro configuration
  uses: niro-demos/niro-configs/.github/actions/install@<commit-sha>
  with:
    repository: ${{ github.repository }}
```

The action refuses to overwrite an existing `niro/` directory unless
`replace: "true"` is explicitly supplied.

## Import a candidate

```bash
python3 scripts/catalog.py import \
  --repository niro-demos/gitea \
  --archive ./niro-knowledge.tar \
  --upstream go-gitea/gitea \
  --upstream-sha <tested-commit> \
  --niro-version <version> \
  --source-run https://github.com/niro-demos/gitea/actions/runs/<run-id>
```

Then inspect the diff, run `python3 scripts/catalog.py validate`, and open a PR.

## Prepare demo repositories

Demo-fleet workflow ownership also lives here:

```bash
scripts/prep-niro-demos-forks.sh --apply --only=workflows gitea casdoor
```

The generated workflows use the immutable installer commit above. Repositories
without an approved entry are skipped and let Niro perform its normal first-run
initialization.
