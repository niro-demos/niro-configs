#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cat >"$ROOT/niro/credentials.yaml" <<'EOF'
credentials:
  - description: "Global administrator in built-in; full instance-wide management privileges. Login through the web sign-in for app-built-in with organization built-in and username admin. Use for vertical authorization comparisons."
    type: username_password
    identifier: admin
    secret: "123"
  - description: "Standard non-admin user A in niro-org; owns only the niro-user-a identity. Login through app-niro with organization niro-org and username niro-user-a. Pair with user B for horizontal tests."
    type: username_password
    identifier: niro-user-a
    secret: "Niro-user-a-2026!"
  - description: "Standard non-admin user B in niro-org; owns only the niro-user-b identity. Login through app-niro with organization niro-org and username niro-user-b. Pair with user A for horizontal tests."
    type: username_password
    identifier: niro-user-b
    secret: "Niro-user-b-2026!"
  - description: "Organization-scoped admin in niro-org (isAdmin=true), not a built-in global admin. Login through app-niro with organization niro-org and username niro-org-admin. Compare org administration against global built-in administration."
    type: username_password
    identifier: niro-org-admin
    secret: "Niro-org-admin-2026!"
EOF
cat >"$ROOT/niro/fixtures.yaml" <<'EOF'
fixtures:
  - name: target_organization
    description: "Dedicated organization containing the non-global test actors."
    value: niro-org
  - name: target_application
    description: "Dedicated application used to sign in the niro-org actors."
    value: app-niro
  - name: horizontal_user_ids
    description: "Distinct identity resources for cross-user authorization checks."
    value: ["niro-org/niro-user-a", "niro-org/niro-user-b"]
  - name: global_admin_id
    description: "Built-in global administrator identity."
    value: built-in/admin
EOF
chmod 600 "$ROOT/niro/credentials.yaml"
