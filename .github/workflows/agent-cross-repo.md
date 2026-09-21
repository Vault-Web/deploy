---
description: Detects contract drift between Vault-Web services every two weeks.
intent: Catch the cases where a change in one Vault-Web service silently broke an assumption another service, the deployment configuration, or the documentation still makes — and report each one where it needs to be fixed.

on:
  schedule: every 14 days
  workflow_dispatch:
  skip-if-match:
    query: "is:issue is:open label:agent-cross-repo"
    max: 3
    scope: none

permissions:
  contents: read
  issues: read
  pull-requests: read

timeout-minutes: 30
max-turns: 90
max-ai-credits: 250
max-daily-ai-credits: 300

concurrency:
  group: "agent-cross-repo"

tools:
  github:
    mode: gh-proxy
    toolsets: [repos, issues, pull_requests]
    allowed-repos: ["vault-web/*"]
    min-integrity: approved

safe-outputs:
  create-issue:
    max: 2
    title-prefix: "[cross-repo] "
    labels: [agent-cross-repo]
    target-repo: "vault-web/deploy"
    allowed-repos:
      - "vault-web/vault-web"
      - "vault-web/cloud-page"
      - "vault-web/password-manager"
      - "vault-web/auth-api-gateway"
      - "vault-web/server-docs"

network:
  allowed: [defaults]
---

# Cross-Repository Consistency

Vault-Web is several services that have to agree with each other:

- `auth-api-gateway` — JWT authentication and authorization for everything else
- `vault-web` — the portal
- `cloud-page` — the file manager
- `password-manager` — the password manager
- `server-docs` — the documentation
- `deploy` — Docker Compose and the submodule pins that tie the versions together

Your job is to find places where one of them changed and another still assumes the
old behaviour.

## Where drift usually hides

- **Authentication contracts** — `auth-api-gateway` changes a scope, claim, token
  lifetime, or endpoint, and a consuming service still expects the previous shape.
- **API contracts** — a service changes a route, payload, or status code that
  another one calls.
- **Deployment configuration** — `deploy` pins a submodule commit, sets an
  environment variable, or wires a port that no longer matches the service.
- **Documentation** — `server-docs` describes setup, architecture, or security
  behaviour that the code has since moved away from.

## How to investigate

Start from what changed recently. Look at merged pull requests and commits in each
repository over the last few weeks, then check whether the repositories that depend
on that change followed it. The submodule pins in `deploy` tell you which versions
are actually deployed together — that is usually the fastest way to spot a gap.

## Reporting

File **at most two** issues, and none when you find nothing solid. This runs every
two weeks; an empty run is a normal outcome, not a failure.

File each issue in the repository that needs to change. If `auth-api-gateway`
changed a scope and `vault-web` did not follow, the issue belongs in `vault-web`.
When it is genuinely unclear which side is wrong, file it in `deploy`.

Each issue names both sides: what changed, where, what still assumes the old
behaviour, and what would break at runtime. Include the commits or pull requests
you based this on, so a maintainer can verify your reasoning quickly.

Do not report a mismatch you have not actually confirmed by reading both sides.
A speculative cross-repo issue is expensive, because whoever reads it has to check
two repositories to dismiss it.
