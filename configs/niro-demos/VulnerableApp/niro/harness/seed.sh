#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE_URL="http://172.17.0.1:9090/VulnerableApp"

for level in 1 2 3 4 5 6 7; do
  marker="niro-seeded-comment-level-$level"
  response="$(curl --fail --silent --show-error --get \
    --data-urlencode "comment=$marker" \
    "$BASE_URL/PersistentXSSInHTMLTagVulnerability/LEVEL_$level")"
  if [[ "$response" != *"$marker"* ]]; then
    echo "Persistent-XSS fixture failed for LEVEL_$level" >&2
    exit 1
  fi
done

cat >"$ROOT/niro/credentials.yaml" <<'EOF'
credentials:
  - credential_id: STANDARD_USER_A
    description: "Session-management standard user A (database id 1, role USER, no extra privilege flags). Login with JSON {username,password} to POST /VulnerableApp/SessionManagementVulnerability/LEVEL_1?action=login; the same credentials work for levels 2-6. Own identity is distinct from STANDARD_USER_B for horizontal checks."
    type: username_password
    identifier: session_user
    secret: password123
  - credential_id: STANDARD_USER_B
    description: "Session-management standard user B (database id 2, role USER) with the seeded malicious flag enabled; this flag only makes the profile endpoint return an intentionally malicious display payload and grants no administrative capability. Same login shape as STANDARD_USER_A."
    type: username_password
    identifier: session_attacker
    secret: attacker123
  - credential_id: ADMIN_USER
    description: "Session-management administrator (database id 3, role ADMIN, no additional flags). Same JSON login endpoint and level selection as STANDARD_USER_A; use for vertical authorization comparisons."
    type: username_password
    identifier: session_admin
    secret: AdminPassword@123
  - credential_id: AUTH_LOG_ADMIN
    description: "AuthenticationVulnerability LEVEL_2 seeded admin (role ADMIN). Submit username and password as query/form parameters to /VulnerableApp/AuthenticationVulnerability/LEVEL_2. The intentionally vulnerable handler records the supplied password in the runtime log sink at niro/harness/run/logs/application.log."
    type: username_password
    identifier: admin_logs
    secret: v9K#2mLp!8zQ
  - credential_id: IDOR_ALICE_LOGIN
    description: "IDOR module Alice actor (database id 1, role USER, salary record owned by Alice, no administrative privileges). Login by POSTing form/query parameters username and password to /VulnerableApp/IDORVulnerability/LEVEL_1 through LEVEL_5; each level returns its own authentication cookie. Referenced by TC-FFEA9A72 as the login actor."
    type: username_password
    identifier: Alice
    secret: P@ssw0rd!2026
  - credential_id: IDOR_ALICE_TEST
    description: "IDOR module Alice test actor (database id 1, role USER, salary record owned by Alice, no administrative privileges). Login by POSTing form/query parameters username and password to /VulnerableApp/IDORVulnerability/LEVEL_1 through LEVEL_5; each level returns its own authentication cookie. Referenced by TC-FFEA9A72 as the authenticated test actor."
    type: username_password
    identifier: Alice
    secret: P@ssw0rd!2026
EOF

cat >"$ROOT/niro/fixtures.yaml" <<'EOF'
fixtures:
  - name: application_base_url
    description: "Base URL of the Niro-managed Spring Boot application built from this checkout."
    value: http://172.17.0.1:9090/VulnerableApp/
  - name: session_management_actors
    description: "Deterministically seeded session-management identities and privilege context."
    value:
      standard_user_a: {id: 1, role: USER, malicious: false}
      standard_user_b: {id: 2, role: USER, malicious: true}
      admin_user: {id: 3, role: ADMIN, malicious: false}
      rate_limit_victim: {id: 4, role: USER, malicious: false}
  - name: idor_users
    description: "Deterministically seeded IDOR module records for object-level authorization testing."
    value:
      - {id: 1, username: Alice, salary: 50000, role: USER}
      - {id: 2, username: Bob, salary: 60000, role: USER}
      - {id: 3, username: Charlie, salary: 70000, role: ADMIN}
  - name: h2_console
    description: "Development H2 console exposed by this intentionally vulnerable local application."
    value:
      url: http://172.17.0.1:9090/VulnerableApp/h2
      jdbc_url: jdbc:h2:mem:testdb
      username: admin
  - name: runtime_log_sink
    description: "Host-side evidence sink for the current runtime logs. AuthenticationVulnerability LEVEL_2 login attempts are synchronously observable here."
    value: niro/harness/run/logs/application.log
  - name: persistent_xss_comments
    description: "One deterministic persisted comment per stored-XSS level. Retrieve a level without a comment parameter to observe stored activity; submit a new comment parameter to create an exploit-specific activity."
    value:
      endpoint_template: http://172.17.0.1:9090/VulnerableApp/PersistentXSSInHTMLTagVulnerability/LEVEL_{level}
      levels: [1, 2, 3, 4, 5, 6, 7]
      marker_template: niro-seeded-comment-level-{level}
EOF
