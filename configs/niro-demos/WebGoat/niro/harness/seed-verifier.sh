#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base="http://127.0.0.1:18080/WebGoat"

register() {
  local username="$1" password="$2" cookie
  cookie="$(mktemp "$here/run/verifier-cookie.XXXXXX")"
  curl --fail --silent --show-error -L \
    -c "$cookie" -b "$cookie" \
    -d "username=$username" -d "password=$password" \
    -d "matchingPassword=$password" -d "agree=agree" \
    "$base/register.mvc" >/dev/null
  curl --fail --silent --show-error -c "$cookie" -b "$cookie" \
    "$base/service/lessonmenu.mvc" >/dev/null
  rm -f "$cookie"
}

register verify-user-a Vrfy123!
register verify-user-b Vrfy456!
