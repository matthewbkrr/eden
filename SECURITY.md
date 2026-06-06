# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report them privately via GitHub's **private vulnerability reporting**:

- Go to the repository's **Security** tab → **Report a vulnerability**, or open
  <https://github.com/matthewbkrr/eden/security/advisories/new>.

Please include:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept),
- affected component (e.g. Accounts / Chat / Storage) and version/commit,
- any suggested remediation.

We aim to acknowledge reports on a best-effort basis and will coordinate a fix
and disclosure timeline with you.

## Supported versions

eden is pre-release. Only the `main` branch is supported; fixes land there.

## Scope

In scope: authentication, authorization/permissions, message and account data
handling, file/photo storage, and any handling of untrusted input. When in
doubt, report privately and we'll triage.
