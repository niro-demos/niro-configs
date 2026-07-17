#!/usr/bin/env bash
#
# Remove GitHub Actions workflow files whose workflow title does not contain
# "niro" (case-insensitive). Changes are proposed on a branch and draft PR.
#
# SAFE BY DEFAULT: without --apply, this only lists workflow files that would
# be removed. The GitHub CLI must be installed and authenticated.
#
# Usage:
#   scripts/remove-non-niro-workflows.sh OWNER/REPOSITORY
#   scripts/remove-non-niro-workflows.sh --apply OWNER/REPOSITORY

set -euo pipefail

DO_APPLY=0
REPOSITORY=""

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      DO_APPLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown flag '$1' (try --help)" >&2
      exit 2
      ;;
    *)
      if [ -n "$REPOSITORY" ]; then
        echo "error: expected exactly one OWNER/REPOSITORY argument" >&2
        exit 2
      fi
      REPOSITORY="$1"
      ;;
  esac
  shift
done

if [ -z "$REPOSITORY" ]; then
  echo "error: missing OWNER/REPOSITORY argument (try --help)" >&2
  exit 2
fi

if ! [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: repository must have the form OWNER/REPOSITORY" >&2
  exit 2
fi

command -v gh >/dev/null 2>&1 || {
  echo "error: gh not found — https://cli.github.com" >&2
  exit 1
}

gh auth status >/dev/null 2>&1 || {
  echo "error: not logged in — run: gh auth login" >&2
  exit 1
}

if ! workflows="$(
  gh api --paginate \
    "repos/$REPOSITORY/actions/workflows?per_page=100" \
    --jq '.workflows[] | [.path, .name] | @tsv'
)"; then
  echo "error: could not list workflows in $REPOSITORY" >&2
  exit 1
fi

if [ -z "$workflows" ]; then
  echo "No GitHub Actions workflows in $REPOSITORY."
  exit 0
fi

deletion_candidates=""
delete_count=0
preserve_count=0

while IFS=$'\t' read -r path title; do
  case "$title" in
    *[Nn][Ii][Rr][Oo]*)
      preserve_count=$((preserve_count + 1))
      ;;
    *)
      if [ -n "$deletion_candidates" ]; then
        deletion_candidates+=$'\n'
      fi
      deletion_candidates+="$path"$'\t'"$title"
      delete_count=$((delete_count + 1))
      ;;
  esac
done <<< "$workflows"

echo "Preserving $preserve_count workflow(s) whose title contains 'niro'."

if [ "$delete_count" -eq 0 ]; then
  echo "No workflows need to be removed from $REPOSITORY."
  exit 0
fi

echo "Workflow files to remove from $REPOSITORY:"
while IFS=$'\t' read -r path title; do
  printf '  %s (%s)\n' "$path" "$title"
done <<< "$deletion_candidates"

if [ "$DO_APPLY" -eq 0 ]; then
  echo
  echo "Dry run: $delete_count workflow file(s) would be removed."
  echo "Run again with --apply to open a draft pull request for the removals."
  exit 0
fi

command -v git >/dev/null 2>&1 || {
  echo "error: git not found" >&2
  exit 1
}

if ! default_branch="$(
  gh repo view "$REPOSITORY" \
    --json defaultBranchRef \
    --jq '.defaultBranchRef.name // empty'
)" || [ -z "$default_branch" ]; then
  echo "error: could not determine the default branch for $REPOSITORY" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT

branch="niro/remove-non-niro-workflows-$(date -u +%Y%m%d%H%M%S)-$$"

git clone --depth 1 --filter=blob:none --no-checkout --quiet \
  "https://github.com/$REPOSITORY.git" "$work_dir/repository"

(
  cd "$work_dir/repository"
  git sparse-checkout set .github/workflows
  git checkout -q "$default_branch"
  git switch -c "$branch" >/dev/null

  while IFS=$'\t' read -r path title; do
    case "$path" in
      .github/workflows/*.yml|.github/workflows/*.yaml)
        file_name="${path#.github/workflows/}"
        ;;
      *)
        echo "error: refusing unsafe workflow path: $path" >&2
        exit 1
        ;;
    esac

    case "$file_name" in
      ""|*/*)
        echo "error: refusing unsafe workflow path: $path" >&2
        exit 1
        ;;
    esac

    if [ ! -f "$path" ]; then
      echo "error: workflow file is missing from the checkout: $path" >&2
      exit 1
    fi

    rm -- "$path"
  done <<< "$deletion_candidates"

  git add -u -- .github/workflows
  if git diff --cached --quiet; then
    echo "error: no workflow deletions to commit" >&2
    exit 1
  fi

  git commit -q -m "ci: remove non-Niro workflows"
  git push -q -u origin "$branch"

  pull_request_url="$(
    gh pr create \
      --repo "$REPOSITORY" \
      --base "$default_branch" \
      --head "$branch" \
      --draft \
      --title "ci: remove non-Niro workflows" \
      --body "Removes $delete_count GitHub Actions workflow file(s) whose workflow title does not contain 'niro' (case-insensitive)."
  )"
  echo "Opened draft pull request: $pull_request_url"
)
