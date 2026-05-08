# Security policy

## Reporting a vulnerability

If you believe you've found a security vulnerability in this template, please
**do not open a public issue**. Instead, email the maintainer privately or use
GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) feature on this repo.

Please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (or a proof-of-concept).
- Affected versions / commit SHA.

You should receive an acknowledgement within five business days. We aim to
provide a fix or mitigation guidance within 30 days for confirmed issues.

## Scope

This template is a public **dev sample** — APIM has no auth, the Function uses
anonymous authorization, and every resource is on the public network by
default. Issues that require enabling those defaults to manifest are still
welcome but will typically be classified as documentation/hardening rather
than vulnerabilities.

In-scope examples:

- Secrets logged or returned in responses.
- Idempotency key collision/replay flaws.
- Bicep templates that grant excessive RBAC scope.
- Path-traversal or injection in policy expressions.

Out-of-scope examples:

- Public network exposure (documented; opt-in lockdown is your job).
- Anonymous Function endpoints (documented).
- DoS via the public APIM gateway URL.
