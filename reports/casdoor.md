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

- **30 confirmed vulnerabilities:** 7 critical, 10 high, and 13 medium.
- **24 focused fix pull requests** opened during the same 3-hour, 12-minute
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
| OAuth client isolation | [PR #21](https://github.com/niro-demos/casdoor/pull/21) |
| Session-secret redaction | [PR #25](https://github.com/niro-demos/casdoor/pull/25) |
| Cross-origin authorization | [PR #27](https://github.com/niro-demos/casdoor/pull/27) |
| Audit-log tenant scoping | [PR #30](https://github.com/niro-demos/casdoor/pull/30) |
| Resource ownership | [PR #32](https://github.com/niro-demos/casdoor/pull/32) |
| SCIM organization boundaries | [PR #36](https://github.com/niro-demos/casdoor/pull/36) |
| Server-side request forgery | [PR #40](https://github.com/niro-demos/casdoor/pull/40) |
| Redirect allow-list enforcement | [PR #43](https://github.com/niro-demos/casdoor/pull/43) |

[View all 24 pull requests created during the run](https://github.com/niro-demos/casdoor/pulls?q=is%3Apr+created%3A2026-07-15T04%3A50%3A00Z..2026-07-15T08%3A03%3A00Z)

## Reproduce and inspect

- [Successful Niro Fix workflow run](https://github.com/niro-demos/casdoor/actions/runs/29389934724)
- [Exact tested commit](https://github.com/niro-demos/casdoor/commit/9cead9a7273d454ec6d823f0f2f322456c64158b)
- [Reviewed reusable Niro configuration](../configs/niro-demos/casdoor/niro)

The generated 53-page PDF is not committed here. It is marked confidential and
contains exploit-level evidence intended for the application owner. This public
summary preserves the demonstrable outcome and reviewable code changes without
publishing sensitive test details.
