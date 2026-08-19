# Casdoor demo: confirmed vulnerabilities to fix pull requests

Niro ran in GitHub Actions against a local instance of the
[`niro-demos/casdoor`](https://github.com/niro-demos/casdoor) demo fork. In one
run, it tested the running application, proved exploitable behavior with live
evidence, produced a structured penetration-test report, and opened focused fix
pull requests for review.

> This is a reproducible product demonstration against the exact demo commit
> linked below. It is not a security assessment of the current upstream
> Casdoor project.

## Outcome

- **33 confirmed vulnerabilities:** 9 critical, 12 high, and 12 medium.
- **28 focused fix pull requests** opened during the same 4-hour, 29-minute
  workflow run.
- **Evidence before remediation:** each confirmed issue included business
  impact, a live reproduction, supporting evidence, and recommended remediation.
- **Explicit uncertainty:** three untestable areas were recorded as coverage
  gaps rather than treated as passing controls.

The generated fixes were left as pull requests. Niro did not merge them;
developers retain control of review, testing, and what ships.

## Representative remediation

| Area | Reviewable change |
| --- | --- |
| Cross-tenant authorization | [PR #245](https://github.com/niro-demos/casdoor/pull/245) |
| LDAP tenant isolation | [PR #247](https://github.com/niro-demos/casdoor/pull/247) |
| Platform signing-key access | [PR #249](https://github.com/niro-demos/casdoor/pull/249) |
| SAML redirect allow list | [PR #252](https://github.com/niro-demos/casdoor/pull/252) |
| SCIM organization boundaries | [PR #258](https://github.com/niro-demos/casdoor/pull/258) |
| Server-side request forgery | [PR #261](https://github.com/niro-demos/casdoor/pull/261) |
| OAuth secret redaction | [PR #263](https://github.com/niro-demos/casdoor/pull/263) |
| Session-secret redaction | [PR #271](https://github.com/niro-demos/casdoor/pull/271) |

[View all 28 pull requests created during the run](https://github.com/niro-demos/casdoor/pulls?q=is%3Apr+created%3A2026-08-17T18%3A20%3A00Z..2026-08-17T22%3A50%3A00Z)

## Reproduce and inspect

- [Successful Niro Fix workflow run](https://github.com/niro-demos/casdoor/actions/runs/32054406790)
- [Exact tested commit](https://github.com/niro-demos/casdoor/commit/0c7f4748f83ab07fdd74ccd2f79a90b1bf8073d7)
- [Reviewed reusable Niro configuration](../configs/niro-demos/casdoor/niro)

The generated 64-page PDF is not committed here. It is marked confidential and
contains exploit-level evidence intended for the application owner. This public
summary preserves the demonstrable outcome and reviewable code changes without
publishing sensitive test details.
