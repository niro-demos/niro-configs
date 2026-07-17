#!/usr/bin/env bash
#
# Close every open pull request in one GitHub repository.
#
# SAFE BY DEFAULT: without --apply, this only lists the pull requests that
# would be closed. The GitHub CLI must be installed and authenticated.
#
# Usage:
#   scripts/close-pull-requests.sh OWNER/REPOSITORY
#   scripts/close-pull-requests.sh --apply OWNER/REPOSITORY

set -euo pipefail

DO_APPLY=0
REPOSITORY=""

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

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

if ! pull_requests="$(
  gh api --paginate --method GET \
    "repos/$REPOSITORY/pulls?state=open&per_page=100" \
    --jq '.[] | [.number, .title] | @tsv'
)"; then
  echo "error: could not list open pull requests in $REPOSITORY" >&2
  exit 1
fi

if [ -z "$pull_requests" ]; then
  echo "No open pull requests in $REPOSITORY."
  exit 0
fi

pull_request_count="$(
  printf '%s\n' "$pull_requests" | wc -l | tr -d '[:space:]'
)"

if [ "$DO_APPLY" -eq 0 ]; then
  echo "Open pull requests in $REPOSITORY:"
  while IFS=$'\t' read -r number title; do
    printf '  #%s %s\n' "$number" "$title"
  done <<< "$pull_requests"
  echo
  echo "Dry run: $pull_request_count pull request(s) would be closed."
  echo "Run again with --apply to close them."
  exit 0
fi

echo "Closing $pull_request_count pull request(s) in $REPOSITORY..."
closed=0
failures=0

while IFS=$'\t' read -r number title; do
  printf 'Closing #%s %s\n' "$number" "$title"
  if gh pr close "$number" --repo "$REPOSITORY"; then
    closed=$((closed + 1))
  else
    echo "error: failed to close #$number" >&2
    failures=$((failures + 1))
  fi
done <<< "$pull_requests"

echo "Closed $closed pull request(s); $failures failed."
[ "$failures" -eq 0 ]
