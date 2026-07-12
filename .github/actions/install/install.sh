#!/usr/bin/env bash
set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$action_dir/../../.." && pwd)"
workspace="${GITHUB_WORKSPACE:-$PWD}"
repository="${NIRO_CONFIG_REPOSITORY:?repository input is required}"
destination="${NIRO_CONFIG_DESTINATION:-niro}"
replace="${NIRO_CONFIG_REPLACE:-false}"

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

python3 "$root/scripts/catalog.py" validate \
  --root "$root" \
  --repository "$repository"

source_dir="$root/configs/$repository/niro"
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
