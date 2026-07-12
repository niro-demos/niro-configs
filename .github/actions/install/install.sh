#!/usr/bin/env bash
set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$action_dir/../../.." && pwd)"
workspace="${GITHUB_WORKSPACE:-$PWD}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
destination="${NIRO_CONFIG_DESTINATION:-niro}"
replace="${NIRO_CONFIG_REPLACE:-false}"
if_missing="${NIRO_CONFIG_IF_MISSING:-skip}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: repository must be owner/name" >&2
  exit 2
fi

case "$destination" in
  ""|/*|*".."*)
    echo "error: destination must be a workspace-relative path without '..'" >&2
    exit 2
    ;;
esac

case "/$destination/" in
  *"/./"*)
    echo "error: destination must be a workspace-relative child path" >&2
    exit 2
    ;;
esac

case "$replace" in
  true|false) ;;
  *)
    echo "error: replace must be 'true' or 'false'" >&2
    exit 2
    ;;
esac

case "$if_missing" in
  skip|error) ;;
  *)
    echo "error: if-missing must be 'skip' or 'error'" >&2
    exit 2
    ;;
esac

source_dir="$root/configs/$repository/niro"
if [ ! -d "$source_dir" ]; then
  if [ "$if_missing" = "skip" ]; then
    echo "No approved Niro configuration for $repository; Niro will initialize it"
    exit 0
  fi
  echo "error: no approved Niro configuration for $repository" >&2
  exit 1
fi

installable="$(python3 "$root/scripts/catalog.py" installable \
  --root "$root" \
  --repository "$repository")"

if [ "$installable" != "true" ]; then
  echo "Saved Niro state for $repository is partial and will not be installed"
  exit 0
fi

target="$workspace/$destination"

if [ -L "$target" ]; then
  echo "error: destination is a symlink: $destination" >&2
  exit 1
fi

if [ -e "$target" ]; then
  if [ "$replace" != "true" ]; then
    echo "error: destination already exists; set replace: 'true' to replace it" >&2
    exit 1
  fi
  rm -rf "$target"
fi

mkdir -p "$(dirname "$target")"
stage="$(mktemp -d "$workspace/.niro-config-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$source_dir" "$stage/niro"
mv "$stage/niro" "$target"

echo "Installed approved Niro configuration for $repository at $destination"
