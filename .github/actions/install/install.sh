#!/usr/bin/env bash
set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$action_dir/../../.." && pwd)"
workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
repository="${NIRO_CONFIG_REPOSITORY:?repository input is required}"
niro_dir="${NIRO_CONFIG_NIRO_DIR:?niro-dir input is required}"
install_root="${NIRO_CONFIG_INSTALL_ROOT:?install-root input is required}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: repository must be owner/name" >&2
  exit 2
fi

case "$niro_dir" in
  ""|.|..|*/*)
    echo "error: niro-dir must be a single directory name" >&2
    exit 2
    ;;
esac

case "$install_root" in
  /*) ;;
  *)
    echo "error: install-root must be an absolute path" >&2
    exit 2
    ;;
esac

if [ ! -d "$workspace" ] || [ ! -d "$install_root" ]; then
  echo "error: GITHUB_WORKSPACE and install-root must be existing directories" >&2
  exit 2
fi

workspace_real="$(cd "$workspace" && pwd -P)"
install_root_real="$(cd "$install_root" && pwd -P)"
case "$install_root_real" in
  "$workspace_real"|"$workspace_real"/*) ;;
  *)
    echo "error: install-root must be inside GITHUB_WORKSPACE" >&2
    exit 2
    ;;
esac

config_root="$root/configs/$repository"
if [ ! -d "$config_root" ]; then
  echo "No approved Niro configuration for $repository; Niro will initialize it"
  exit 0
fi

installable="$(python3 "$root/scripts/catalog.py" installable \
  --root "$root" \
  --repository "$repository" \
  --niro-dir "$niro_dir")"

if [ "$installable" != "true" ]; then
  echo "Saved Niro state for $repository is partial and will not be installed"
  exit 0
fi

source_dir="$config_root/$niro_dir"
target="$install_root_real/$niro_dir"

if [ -L "$target" ]; then
  echo "error: destination is a symlink: $target" >&2
  exit 1
fi

if [ -e "$target" ]; then
  rm -rf "$target"
fi

mkdir -p "$(dirname "$target")"
stage="$(mktemp -d "$workspace/.niro-config-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$source_dir" "$stage/niro"
mv "$stage/niro" "$target"

echo "Installed approved Niro configuration for $repository at $target"
