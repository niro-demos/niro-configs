#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
config="$(cd "$here/.." && pwd)"
base="http://127.0.0.1:8080/WebGoat"

register() {
  local username="$1" password="$2" cookie
  cookie="$(mktemp "$here/run/cookie.XXXXXX")"
  trap 'rm -f "$cookie"' RETURN
  curl --fail --silent --show-error -L \
    -c "$cookie" -b "$cookie" \
    -d "username=$username" \
    -d "password=$password" \
    -d "matchingPassword=$password" \
    -d "agree=agree" \
    "$base/register.mvc" >/dev/null
  curl --fail --silent --show-error -c "$cookie" -b "$cookie" \
    "$base/service/lessonmenu.mvc" >/dev/null
  rm -f "$cookie"
  trap - RETURN
}

register niro-user-a Goat123!
register niro-user-b Goat456!

cat >"$config/credentials.yaml" <<'EOF'
credentials:
  - description: "Learner A. Login at POST /WebGoat/login with form fields username and password. Owns an isolated per-user lesson database, lesson progress, mailbox, and WebWolf state. Pair with Learner B for horizontal authorization tests. WebGoat defines no admin role; this principal has only the standard authenticated learner authority."
    type: username_password
    identifier: niro-user-a
    secret: Goat123!
  - description: "Learner B. Login at POST /WebGoat/login with form fields username and password. Owns a different isolated per-user lesson database, lesson progress, mailbox, and WebWolf state. Pair with Learner A for cross-user tests. WebGoat defines no admin role; this principal has only the standard authenticated learner authority."
    type: username_password
    identifier: niro-user-b
    secret: Goat456!
EOF

cat >"$config/fixtures.yaml" <<'EOF'
fixtures:
  - name: webgoat_surface
    description: "Primary WebGoat application and lesson surface served by the current checkout."
    value: "http://host.docker.internal:8080/WebGoat/"
  - name: webwolf_surface
    description: "Companion WebWolf surface used by WebGoat lessons, sharing the seeded learner identities."
    value: "http://host.docker.internal:9090/WebWolf/"
  - name: learner_pair
    description: "Two distinct standard learners with separate per-user lesson databases and application state for horizontal authorization comparisons."
    value:
      - niro-user-a
      - niro-user-b
  - name: challenge7_mailboxes
    description: "Deliverable local email-shaped inputs for Challenge 7. The endpoint derives the mailbox recipient from the portion before @; these prefixes match the seeded learner usernames."
    value:
      learner_a: niro-user-a@example.test
      learner_b: niro-user-b@example.test
  - name: destructive_verifier_target
    description: "Isolated disposable runtime reserved for destructive verification of TC-E9B73331. Its learners and mailbox state are separate from the primary sweep runtime."
    value:
      webgoat_url: http://host.docker.internal:18080/WebGoat/
      webwolf_url: http://host.docker.internal:19090/WebWolf/
      learners:
        - verify-user-a
        - verify-user-b
EOF
