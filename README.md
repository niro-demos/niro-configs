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

## Saved applications

| Repository | State | Source run |
| --- | --- | --- |
| `niro-demos/casdoor` | Installable | Successful Codex run |
| `niro-demos/dify` | Installable | Config completed before Claude session limit |
| `niro-demos/gitea` | Installable | Successful Codex run |
| `niro-demos/saleor` | Partial, not installed | Claude session limit interrupted setup |

OpenObserve is intentionally absent because its Copilot run failed before Niro
produced usable configuration.

## Install in a workflow

Pin the action to an immutable commit:

```yaml
- name: Install approved Niro configuration
  uses: niro-demos/niro-configs/.github/actions/install@<commit-sha>
  with:
    replace: "true"
```

The action selects `configs/$GITHUB_REPOSITORY/niro` automatically. It refuses
to overwrite an existing `niro/` directory unless `replace: "true"` is
explicitly supplied.

## Import a candidate

```bash
python3 scripts/catalog.py import \
  --repository niro-demos/gitea \
  --archive ./niro-knowledge.tar \
  --upstream go-gitea/gitea \
  --upstream-sha <tested-commit> \
  --niro-version <version> \
  --source-run https://github.com/niro-demos/gitea/actions/runs/<run-id> \
  --source-run-conclusion success
```

Then inspect the diff, run `python3 scripts/catalog.py validate`, and open a PR.
Use `--partial` only to preserve interrupted setup state; the installer validates
it but deliberately skips it until a later run produces a complete config.

## Prepare demo repositories

Demo-fleet workflow ownership also lives here:

```bash
scripts/prep-niro-demos-forks.sh --apply --only=workflows gitea casdoor
```

The generated workflows use the immutable installer commit above. Repositories
without an approved entry are skipped and let Niro perform its normal first-run
initialization.
