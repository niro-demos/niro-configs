# Niro demo configuration catalog

This repository stores reviewed, reusable Niro configuration for applications in
the [`niro-demos`](https://github.com/niro-demos) organization. Reusing a proven
configuration avoids paying the setup time and model cost on every pentest.

This README is the shared contract for human contributors and coding agents.
Repository-specific agent instructions in `AGENTS.md` require agents to follow
the same lifecycle and safety boundary described here.

## Quick start for a project

Add the installer immediately after `actions/checkout` and before running Niro:

```yaml
- name: Install approved Niro configuration
  uses: niro-demos/niro-configs/.github/actions/install@bde2a5e55557ae08df03d74b40d996ce32d755d4
  with:
    repository: ${{ github.repository }}
    niro-dir: niro
    install-root: ${{ github.workspace }}
```

All three inputs are required:

- `repository` selects `configs/<owner>/<repo>` in this catalog.
- `niro-dir` selects the named configuration directory, such as `niro` or
  `niro-staging`.
- `install-root` is the absolute parent directory where that Niro directory is
  installed. It must already exist inside `GITHUB_WORKSPACE`.

The action copies:

```text
configs/<repository>/<niro-dir>
    -> <install-root>/<niro-dir>
```

An approved entry replaces the destination in the temporary CI workspace. If
the repository has no catalog entry, installation is a no-op and Niro performs
its normal first-run initialization. A known repository with the wrong
`niro-dir`, an unsafe path, or invalid catalog content fails closed.

Project repositories use the installer action above. They do not use this
repository's `.github/workflows/ci.yml`.

## Catalog lifecycle

1. A project workflow installs its approved config before `niro find` or
   `niro fix`.
2. Niro uploads `niro-knowledge.tar` after the run.
3. A trusted contributor imports a complete artifact on a feature branch.
4. The contributor reviews the sanitized diff and opens a PR.
5. This repository's CI automatically runs tests, shell syntax checks, and
   catalog validation.
6. A human reviews and merges the PR. CI validates; it never merges.

The pentest agent never receives a credential that can write to this repository.

## What may be stored

The catalog keeps declarative Niro files, acceptance registers, example files,
and reviewed harness source. Every published entry must be complete and
installable.

The importer and validator reject or remove:

- real `credentials.yaml` and `fixtures.yaml` files;
- findings and debug logs;
- harness runtime state and caches;
- archives, binary files, private-key files, and symlinks.

Example credential and fixture templates are allowed because they describe
public demo seed data rather than live secrets. Incomplete artifacts must not be
published; run Niro again and import the completed artifact instead.

## Saved applications

| Repository | Source run |
| --- | --- |
| `niro-demos/casdoor` | Successful Codex run |
| `niro-demos/dify` | Configuration completed before Claude reached its session limit |
| `niro-demos/gitea` | Successful Codex run |

Saleor is absent because its Claude run produced only partial setup. OpenObserve
is absent because Copilot failed before Niro produced usable configuration.

## Add or update a configuration

Create a feature branch, then import a downloaded knowledge artifact:

```bash
python3 scripts/catalog.py import \
  --repository niro-demos/gitea \
  --niro-dir niro \
  --archive ./niro-knowledge.tar \
  --upstream go-gitea/gitea \
  --upstream-sha <tested-commit> \
  --niro-version <version> \
  --source-run https://github.com/niro-demos/gitea/actions/runs/<run-id> \
  --source-run-conclusion success
```

Review every imported file, then run:

```bash
python3 -m unittest discover -s tests -v
python3 scripts/catalog.py validate
bash -n .github/actions/install/install.sh scripts/prep-niro-demos-forks.sh
```

Commit the reviewed changes, push the branch, and open a PR. Do not push catalog
changes directly to `main`.

## Prepare demo workflows

Fleet workflow generation also lives here:

```bash
scripts/prep-niro-demos-forks.sh --apply --only=workflows gitea casdoor
```

The generated Find and Fix workflows use an immutable installer commit. When the
action or catalog changes, update that pin before refreshing project workflows.

## Repository layout

```text
configs/<owner>/<repo>/
  metadata.yaml
  <niro-dir>/
.github/actions/install/
.github/workflows/ci.yml
scripts/
tests/
```

`.github/workflows/ci.yml` belongs only to this catalog repository. GitHub runs
it automatically for every PR and push to `main`; contributors do not invoke it
manually.
