#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
TARGET_URL="http://127.0.0.1:9090/VulnerableApp"

curl --fail --silent --show-error "$TARGET_URL/scanner" >/dev/null

cat >"$CONFIG_DIR/credentials.yaml" <<'EOF'
credentials:
  - description: "IDOR standard user Alice (user ID 1), owns only her salary profile. Login: POST /VulnerableApp/IDORVulnerability/LEVEL_1 through LEVEL_5 as form fields username and password. Pair with Bob for horizontal authorization tests."
    type: username_password
    identifier: Alice
    secret: "P@ssw0rd!2026"
  - description: "IDOR standard user Bob (user ID 2), owns only his salary profile. Login is the same form shape as Alice. Pair with Alice for cross-user profile access tests."
    type: username_password
    identifier: Bob
    secret: "P@ssw0rd!2026"
  - description: "IDOR admin Charlie (user ID 3), global ADMIN for the IDOR module and may access all salary profiles. Login is the same form shape as Alice. Use for vertical authorization comparisons."
    type: username_password
    identifier: Charlie
    secret: "P@ssw0rd!2026"
  - description: "Authentication module level-9 ADMIN account using bcrypt. Login: POST /VulnerableApp/AuthenticationVulnerability/LEVEL_9 with form fields username and password. This module demonstrates credential handling and does not create an app-wide session."
    type: username_password
    identifier: admin_secure
    secret: "9fG#2hJk*LmN!8qR"
EOF

cat >"$CONFIG_DIR/fixtures.yaml" <<'EOF'
fixtures:
  - name: target_base_url
    description: "Exact base URL of the Niro-managed current-checkout runtime."
    value: "http://127.0.0.1:9090/VulnerableApp"
  - name: idor_profiles
    description: "Deterministically bootstrapped IDOR salary profiles for horizontal and vertical authorization testing."
    value:
      alice: {id: 1, role: USER}
      bob: {id: 2, role: USER}
      charlie: {id: 3, role: ADMIN}
  - name: discovery_endpoint
    description: "Application endpoint exposing the complete vulnerability and attack-vector catalog for sweep discovery."
    value: "/scanner"
  - name: h2_console
    description: "Local embedded H2 console exposed by the unsafe test profile."
    value:
      path: "/h2"
      jdbc_url: "jdbc:h2:mem:testdb"
      username: "admin"
EOF
