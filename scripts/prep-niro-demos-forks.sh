#!/usr/bin/env bash
#
# prep-niro-demos-forks.sh
# Make niro-demos repos demo-ready in ONE pass. Per repo:
#   1. resync — hard-reset the default branch to the parent's HEAD (discard demo
#      commits) and delete every other branch (clears niro fix branches, auto-
#      closing their PRs). Keeps repo secrets and settings.
#   2. workflows — remove ALL existing workflows and install a uniform 6 (niro
#      find + fix for claude, codex, copilot), delivered as an auto-merged PR so
#      they land on the default branch. Each workflow installs an approved
#      config from this catalog when one exists.
#
# TARGET: pass one or more repo names to prep just those; pass none to prep ALL
# public forks in the org. A bare name means "niro-demos/<name>"; owner/repo is
# used as-is. (Non-fork demo repos like "sieve" must be named explicitly.)
#
# SAFE BY DEFAULT: without --apply this only REPORTS what it would do (dry run).
# Applying is IRREVERSIBLE (discarded commits/branches are gone).
#
# ADVANCED: --only=resync or --only=workflows runs just one phase. Default (no
# --only) runs both — the "make it demo-ready" path. Use --only=workflows to
# refresh the workflows without disturbing an in-progress demo run.
#
# SECRETS: the installed workflows need org/repo secrets to actually RUN —
# CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY, CODEX_AUTH_JSON_B64 /
# OPENAI_API_KEY, COPILOT_PROVIDER_API_KEY, and NIRO_APP_CLIENT_ID +
# NIRO_APP_PRIVATE_KEY (fix mode). This installs files only.
#
# Prereqs: gh CLI + git, logged in with the `repo` scope — plus the `workflow`
# scope to push workflow files (the workflows phase checks and, if it's missing,
# tells you to run: gh auth refresh -h github.com -s workflow).
#
# Usage:
#   ./prep-niro-demos-forks.sh                   # dry run, ALL public forks
#   ./prep-niro-demos-forks.sh dify              # dry run, just niro-demos/dify
#   ./prep-niro-demos-forks.sh --apply dify      # prep just that one
#   ./prep-niro-demos-forks.sh --apply           # prep ALL public forks
#   ./prep-niro-demos-forks.sh --apply --only=workflows dify

set -euo pipefail

ORG="niro-demos"
BRANCH="niro/standardize-workflows"
DO_APPLY=0
ONLY=""
NAMES=()

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

for a in "$@"; do
  case "$a" in
    --apply)            DO_APPLY=1 ;;
    --only=resync)      ONLY=resync ;;
    --only=workflows)   ONLY=workflows ;;
    -h|--help)          usage; exit 0 ;;
    -*)                 echo "error: unknown flag '$a' (try --help)"; exit 2 ;;
    *)                  NAMES+=("$a") ;;
  esac
done

command -v gh  >/dev/null 2>&1 || { echo "error: gh not found — https://cli.github.com"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not logged in — run: gh auth login"; exit 1; }

do_resync=1; do_workflows=1
[ "$ONLY" = "workflows" ] && do_resync=0
[ "$ONLY" = "resync" ] && do_workflows=0

# Pushing .github/workflows files requires the OAuth `workflow` scope; a
# repo-only token is rejected at push with no PR created. Fail fast on --apply.
if [ "$do_workflows" -eq 1 ] && [ "$DO_APPLY" -eq 1 ]; then
  if ! gh api -i user 2>/dev/null | tr -d '\r' | grep -i '^x-oauth-scopes:' | grep -q 'workflow'; then
    echo "error: pushing workflow files needs the gh 'workflow' scope. Run:"
    echo "  gh auth refresh -h github.com -s workflow"
    exit 1
  fi
fi

# ---- workflow templates ----------------------------------------------------
# Quoted heredocs so the shell never touches ${{ ... }}; @@AGENT@@ is the only
# substitution, via sed. The config action is pinned to a reviewed commit.

find_template() { # $1=agent
  sed "s/@@AGENT@@/$1/g" <<'YAML'
name: Niro Find (@@AGENT@@)

on:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: niro-find-@@AGENT@@-${{ github.ref }}
  cancel-in-progress: false

jobs:
  find:
    name: Pentest and report findings
    runs-on: ubuntu-latest
    timeout-minutes: 300

    steps:
      - name: Check out repository
        uses: actions/checkout@v6
        with:
          persist-credentials: false

      - name: Install approved Niro configuration
        uses: niro-demos/niro-configs/.github/actions/install@940bb956f0ed56c011fe432eb8df13bed4103d39
        with:
          repository: ${{ github.repository }}
          niro-dir: niro
          install-root: ${{ github.workspace }}

      - name: Install Niro
        shell: bash
        run: curl -fsSL https://raw.githubusercontent.com/apxlabs-ai/niro/main/install.sh | sh

      # Codex/Copilot setup and other CI settings:
      # https://github.com/apxlabs-ai/niro/blob/main/docs/ci-environment.md
      - name: Run Niro
        shell: bash
        env:
          CODEX_AUTH_JSON_B64: ${{ secrets.CODEX_AUTH_JSON_B64 }}
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          COPILOT_PROVIDER_API_KEY: ${{ secrets.COPILOT_PROVIDER_API_KEY }}
          COPILOT_PROVIDER_BASE_URL: https://openrouter.ai/api/v1
          COPILOT_PROVIDER_TYPE: openai
          COPILOT_MODEL: z-ai/glm-5.2
        run: niro find --agent=@@AGENT@@ --goal="Pentest this application" --config-dir=niro --include-findings=true --upload-debug-logs=true

      - name: Upload Niro knowledge
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: niro-knowledge
          path: niro-knowledge.tar
          if-no-files-found: ignore
          retention-days: 30

      # Uploads only when the run wrote the tar — enabled explicitly above.
      - name: Upload debug logs
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: niro-debug-logs-unsafe
          path: niro-debug-logs.tar
          if-no-files-found: ignore
          retention-days: 7
YAML
}

fix_template() { # $1=agent
  sed "s/@@AGENT@@/$1/g" <<'YAML'
name: Niro Fix (@@AGENT@@)

on:
  workflow_dispatch:

permissions:
  contents: write
  issues: write
  pull-requests: write
  statuses: write

concurrency:
  group: niro-fix-@@AGENT@@-${{ github.ref }}
  cancel-in-progress: false

jobs:
  fix:
    name: Pentest and open fix PRs
    runs-on: ubuntu-latest
    timeout-minutes: 300

    steps:
      - name: Check out repository
        uses: actions/checkout@v6
        with:
          # Niro pushes and opens PRs with a fresh GitHub App token, so the
          # checkout must not leave its own credential behind for git to use.
          persist-credentials: false

      - name: Install approved Niro configuration
        uses: niro-demos/niro-configs/.github/actions/install@940bb956f0ed56c011fe432eb8df13bed4103d39
        with:
          repository: ${{ github.repository }}
          niro-dir: niro
          install-root: ${{ github.workspace }}

      - name: Install Niro
        shell: bash
        run: curl -fsSL https://raw.githubusercontent.com/apxlabs-ai/niro/main/install.sh | sh

      # Codex/Copilot setup and other CI settings:
      # https://github.com/apxlabs-ai/niro/blob/main/docs/ci-environment.md
      - name: Run Niro
        shell: bash
        env:
          CODEX_AUTH_JSON_B64: ${{ secrets.CODEX_AUTH_JSON_B64 }}
          NIRO_APP_CLIENT_ID: ${{ secrets.NIRO_APP_CLIENT_ID }}
          NIRO_APP_PRIVATE_KEY: ${{ secrets.NIRO_APP_PRIVATE_KEY }}
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          COPILOT_PROVIDER_API_KEY: ${{ secrets.COPILOT_PROVIDER_API_KEY }}
          COPILOT_PROVIDER_BASE_URL: https://openrouter.ai/api/v1
          COPILOT_PROVIDER_TYPE: openai
          COPILOT_MODEL: z-ai/glm-5.2
        run: niro fix --agent=@@AGENT@@ --goal="Pentest this application" --config-dir=niro --include-findings=true --upload-debug-logs=true

      - name: Upload Niro knowledge
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: niro-knowledge
          path: niro-knowledge.tar
          if-no-files-found: ignore
          retention-days: 30

      # Uploads only when the run wrote the tar — enabled explicitly above.
      - name: Upload debug logs
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: niro-debug-logs-unsafe
          path: niro-debug-logs.tar
          if-no-files-found: ignore
          retention-days: 7
YAML
}

write_workflows() { # $1=workflows dir
  local wf="$1" agent
  for agent in claude codex copilot; do
    find_template "$agent" > "$wf/niro-find-$agent.yml"
    fix_template  "$agent" > "$wf/niro-fix-$agent.yml"
  done
}

# ---- resolve targets -------------------------------------------------------
REPOS=()
if [ "${#NAMES[@]}" -gt 0 ]; then
  for n in "${NAMES[@]}"; do
    case "$n" in
      */*) REPOS+=("$n") ;;
      *)   REPOS+=("$ORG/$n") ;;
    esac
  done
else
  echo "Scanning '$ORG' for PUBLIC forks..."
  if ! repo_list=$(gh repo list "$ORG" --fork --visibility public --limit 1000 \
        --json nameWithOwner --jq '.[].nameWithOwner' 2>&1); then
    echo "error: could not list repos in '$ORG':"; echo "$repo_list"; exit 1
  fi
  while IFS= read -r line; do [ -n "$line" ] && REPOS+=("$line"); done <<< "$repo_list"
fi

count=${#REPOS[@]}
[ "$count" -eq 0 ] && { echo "No matching repos. Nothing to do."; exit 0; }

phases="resync + workflows"
[ "$ONLY" = "resync" ] && phases="resync only"
[ "$ONLY" = "workflows" ] && phases="workflows only"

echo "Repos to prep ($count) — phases: $phases"
printf '  %s\n' "${REPOS[@]}"
echo
if [ "$DO_APPLY" -eq 1 ]; then MODE="APPLY"; else MODE="DRY RUN"; fi
echo "Mode: $MODE"
[ "$do_workflows" -eq 1 ] && echo "Reminder: workflows need org/repo secrets to run (CLAUDE_CODE_OAUTH_TOKEN, CODEX_AUTH_JSON_B64, COPILOT_PROVIDER_API_KEY, NIRO_APP_*). Files only."
echo

if [ "$DO_APPLY" -eq 1 ]; then
  printf "About to prep %s repo(s) (%s). This is IRREVERSIBLE.\nType 'prep' to confirm: " "$count" "$phases"
  read -r ans
  [ "$ans" = "prep" ] || { echo "Aborted — nothing changed."; exit 1; }
  echo
fi

# ---- per-repo --------------------------------------------------------------
resync_ok=0; branch_del=0; wf_ok=0; fail=0

for repo in "${REPOS[@]}"; do
  echo "=== $repo ==="

  # ---- phase 1: resync (GitHub API branch-reset; no clone) ----
  if [ "$do_resync" -eq 1 ]; then
    # gh returns parent as {name, owner.login}, not nameWithOwner — build it.
    parent=$(gh repo view "$repo" --json parent \
      --jq 'if .parent then .parent.owner.login + "/" + .parent.name else empty end' 2>/dev/null || true)
    defbranch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name // empty' 2>/dev/null || true)
    if [ -z "$parent" ]; then
      echo "  resync   : skip (no parent — not a fork, or repo not found)"
    elif [ -z "$defbranch" ]; then
      echo "  resync   : skip (no default branch)"
    else
      up_sha=$(gh api "repos/$parent/git/ref/heads/$defbranch" --jq '.object.sha' 2>/dev/null || true)
      fork_sha=$(gh api "repos/$repo/git/ref/heads/$defbranch" --jq '.object.sha' 2>/dev/null || true)
      if [ -z "$up_sha" ]; then
        echo "  resync   : skip (parent $parent has no branch '$defbranch')"
      elif [ "$fork_sha" = "$up_sha" ]; then
        echo "  resync   : $defbranch already at parent HEAD ($up_sha)"
      else
        echo "  resync   : $defbranch ${fork_sha:-?} -> $up_sha (parent $parent)"
      fi
      extra=()
      while IFS= read -r b; do
        [ -n "$b" ] && [ "$b" != "$defbranch" ] && extra+=("$b")
      done < <(gh api "repos/$repo/branches" --paginate --jq '.[].name' 2>/dev/null || true)
      if [ "${#extra[@]}" -gt 0 ]; then echo "  del br.  : ${extra[*]}"; fi

      if [ "$DO_APPLY" -eq 1 ] && [ -n "$up_sha" ]; then
        if [ "$fork_sha" != "$up_sha" ]; then
          if gh api -X PATCH "repos/$repo/git/refs/heads/$defbranch" -f sha="$up_sha" -F force=true >/dev/null 2>&1; then
            echo "  -> resync ok"; resync_ok=$((resync_ok+1))
          else
            echo "  -> resync FAILED"; fail=$((fail+1))
          fi
        fi
        if [ "${#extra[@]}" -gt 0 ]; then
          for b in "${extra[@]}"; do
            if gh api -X DELETE "repos/$repo/git/refs/heads/$b" >/dev/null 2>&1; then
              branch_del=$((branch_del+1))
            else
              echo "  -> FAILED to delete branch $b"; fail=$((fail+1))
            fi
          done
        fi
      fi
    fi
  fi

  # ---- phase 2: workflows (clone -> swap -> PR -> merge) ----
  if [ "$do_workflows" -eq 1 ]; then
    existing=$(gh api "repos/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || true)
    n_existing=$(printf '%s\n' "$existing" | grep -c . || true)
    echo "  workflows: remove ${n_existing:-0} existing -> install 6 niro (find/fix × claude/codex/copilot)"

    if [ "$DO_APPLY" -eq 1 ]; then
      tmp=$(mktemp -d)
      if ! gh repo clone "$repo" "$tmp/r" -- --depth 1 --filter=blob:none --quiet 2>/dev/null; then
        echo "  -> clone FAILED"; fail=$((fail+1)); rm -rf "$tmp"; echo; continue
      fi
      if (
        cd "$tmp/r"
        def=$(git symbolic-ref --short HEAD)
        git checkout -q -b "$BRANCH"
        rm -rf .github/workflows
        mkdir -p .github/workflows
        write_workflows .github/workflows
        git add -A
        git commit -q -m "ci: standardize niro find/fix workflows for claude, codex, copilot

Replace all workflows with a uniform 6 (niro find and fix for each agent),
matching the niro-internal examples. All workflow_dispatch.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
        git push -fq -u origin "$BRANCH"
        url=$(gh pr create --repo "$repo" --base "$def" --head "$BRANCH" \
          --title "ci: standardize niro find/fix workflows (claude, codex, copilot)" \
          --body "Uniform set of 6 niro workflows — find + fix for each agent, matching the niro-internal examples. All workflow_dispatch. Needs org/repo secrets to run." 2>/dev/null \
          || gh pr view "$BRANCH" --repo "$repo" --json url --jq .url)
        gh pr merge "$BRANCH" --repo "$repo" --squash --delete-branch >/dev/null 2>&1
        echo "  -> workflows merged: $url"
      ); then wf_ok=$((wf_ok+1)); else echo "  -> workflows FAILED"; fail=$((fail+1)); fi
      rm -rf "$tmp"
    fi
  fi
  echo
done

echo
if [ "$DO_APPLY" -ne 1 ]; then
  echo "DRY RUN complete — nothing changed. Re-run with --apply to prep."
else
  echo "Done: resync=$resync_ok, branches deleted=$branch_del, workflows=$wf_ok, failures=$fail."
  if [ "$fail" -gt 0 ]; then
    exit 1
  fi
fi
