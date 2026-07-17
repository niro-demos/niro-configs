#!/usr/bin/env bash
#
# Delete GitHub Actions workflow runs unless the visible run title contains
# "Niro Find" or "Niro Fix" (case-insensitive).
#
# SAFE BY DEFAULT: without --apply, this only lists workflow runs that would be
# deleted. Deleting a run also deletes its logs and artifacts and cannot be
# undone. The GitHub CLI must be installed and authenticated.
#
# Usage:
#   scripts/remove-non-niro-workflows.sh OWNER/REPOSITORY
#   scripts/remove-non-niro-workflows.sh --apply OWNER/REPOSITORY

set -euo pipefail

DO_APPLY=0
REPOSITORY=""

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

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

if ! workflow_runs="$(
  gh api --paginate \
    "repos/$REPOSITORY/actions/runs?per_page=100" \
    --jq '.workflow_runs[] | [.id, .display_title, .name] | @tsv'
)"; then
  echo "error: could not list workflow runs in $REPOSITORY" >&2
  exit 1
fi

if [ -z "$workflow_runs" ]; then
  echo "No GitHub Actions workflow runs in $REPOSITORY."
  exit 0
fi

deletion_candidates=""
delete_count=0
preserve_count=0

while IFS=$'\t' read -r run_id run_title workflow_name; do
  case "$run_title" in
    *[Nn][Ii][Rr][Oo]\ [Ff][Ii][Nn][Dd]*|*[Nn][Ii][Rr][Oo]\ [Ff][Ii][Xx]*)
      preserve_count=$((preserve_count + 1))
      ;;
    *)
      if [ -n "$deletion_candidates" ]; then
        deletion_candidates+=$'\n'
      fi
      deletion_candidates+="$run_id"$'\t'"$run_title"$'\t'"$workflow_name"
      delete_count=$((delete_count + 1))
      ;;
  esac
done <<< "$workflow_runs"

echo "Preserving $preserve_count run(s) titled 'Niro Find' or 'Niro Fix'."

if [ "$delete_count" -eq 0 ]; then
  echo "No workflow runs need to be deleted from $REPOSITORY."
  exit 0
fi

echo "Workflow runs to delete from $REPOSITORY:"
while IFS=$'\t' read -r run_id run_title workflow_name; do
  printf '  %s: %s (%s)\n' "$run_id" "$run_title" "$workflow_name"
done <<< "$deletion_candidates"

if [ "$DO_APPLY" -eq 0 ]; then
  echo
  echo "Dry run: $delete_count workflow run(s) would be permanently deleted."
  echo "Run again with --apply to delete them, including their logs and artifacts."
  exit 0
fi

echo "Deleting $delete_count workflow run(s) from $REPOSITORY..."
deleted=0
failures=0

while IFS=$'\t' read -r run_id run_title workflow_name; do
  printf 'Deleting %s: %s (%s)\n' "$run_id" "$run_title" "$workflow_name"
  if gh api --method DELETE \
    "repos/$REPOSITORY/actions/runs/$run_id" \
    --silent; then
    deleted=$((deleted + 1))
  else
    echo "error: failed to delete workflow run $run_id" >&2
    failures=$((failures + 1))
  fi
done <<< "$deletion_candidates"

echo "Deleted $deleted workflow run(s); $failures failed."
[ "$failures" -eq 0 ]
