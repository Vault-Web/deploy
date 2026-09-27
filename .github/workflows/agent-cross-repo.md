---
description: Detects deployment and contract drift across Vault-Web services every two weeks.
intent: Keep the deploy view, service contracts, and concise operational docs aligned across Vault-Web, and route each high-confidence problem to the repository that owns the fix.

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

timeout-minutes: 35
max-turns: 110
max-ai-credits: 320
max-daily-ai-credits: 500

concurrency:
  group: "agent-cross-repo"

tools:
  bash: ["cat", "ls", "find", "grep", "head", "tail", "wc", "sort", "sed", "awk", "jq", "git", "gh"]
  github:
    mode: gh-proxy
    toolsets: [repos, issues, pull_requests]
    allowed-repos: ["vault-web/*"]
    min-integrity: approved

safe-outputs:
  report-failure-as-issue: false
  github-app:
    app-id: ${{ vars.VAULTWEB_AGENT_APP_ID }}
    private-key: ${{ secrets.VAULTWEB_AGENT_APP_KEY }}
  create-issue:
    max: 4
    title-prefix: "[cross-repo] "
    labels: [agent-cross-repo, found-from-deploy]
    allowed-repos:
      - "vault-web/vault-web"
      - "vault-web/cloud-page"
      - "vault-web/auth-api-gateway"
      - "vault-web/server-docs"
      - "vault-web/deploy"
  create-pull-request:
    max: 1
    title-prefix: "[agent] "
    labels: [agent-managed, documentation, found-from-deploy]
    draft: true
    target-repo: "vault-web/deploy"

network:
  allowed: [defaults]
---

# Cross-Repository Consistency

Vault-Web is several repositories that have to agree with each other:

- `auth-api-gateway` — JWT authentication and authorization for everything else
- `vault-web` — the portal
- `cloud-page` — the file manager
- `vaultwarden` — the external password vault deployed from this repository
- `server-docs` — the documentation
- `deploy` — Docker Compose, deployment scripts, high-level operations docs, and
  the submodule pins that tie the versions together

Your job is to inspect the system from the deployment point of view: what is
actually wired together, what the services now require, and whether the concise
operator-facing docs still describe the deployed shape.

## Where drift usually hides

- **Authentication contracts** — `auth-api-gateway` changes a scope, claim, token
  lifetime, or endpoint, and a consuming service still expects the previous shape.
- **API contracts** — a service changes a route, payload, or status code that
  another one calls.
- **Deployment configuration** — `deploy` pins a submodule commit, sets an
  environment variable, exposes a port, names a container, mounts a volume, or
  declares a healthcheck that no longer matches the service.
- **Vaultwarden operations** — the password vault needs a valid HTTPS domain,
  a backed-up `/data` directory, safe signup settings, and a hashed admin token.
- **Operational documentation** — `deploy` or `server-docs` describes setup,
  routing, environment variables, architecture, or security behaviour that the
  code or Compose files have since moved away from.
- **Submodule pins** — the deployed combination is far behind a service's main
  branch, especially when the missing commits changed security, configuration,
  API contracts, or production boot behaviour.

## How to investigate

Start from the deploy repository:

- read `docker-compose*.yml`, deployment scripts, `.env.example`, README files,
  and the checked submodule SHAs;
- compare those assumptions with recent merged pull requests and commits in the
  service repositories;
- check open issues first so you do not duplicate work;
- use the submodule pins in `deploy` as the source of truth for what is actually
  deployed together.

When the relevant docs are merely stale or too sparse at the deployment level,
you may open one small draft pull request against `Vault-Web/deploy`. Keep that
PR professional and concise: high-level architecture, operator-facing setup, and
important current contracts only. Do not generate exhaustive internal reference
docs, and do not rewrite docs for style.

## Reporting

File **at most four** issues, and none when you find nothing solid. This runs
every two weeks; an empty run is a normal outcome, not a failure.

File each issue in the repository that needs to change. If `auth-api-gateway`
changed a scope and `vault-web` did not follow, the issue belongs in `vault-web`.
When it is genuinely unclear which side is wrong, file it in `deploy`.

Every issue found from this deploy-level review must be labelled
`agent-cross-repo` and `found-from-deploy`. Use `deploy-drift` as well when the
problem is specifically about Compose, scripts, ports, submodule pins, runtime
configuration, or deployment docs.

Each issue names both sides: what changed, where, what still assumes the old
behaviour, and what would break at runtime. Include the commits or pull requests
you based this on, so a maintainer can verify your reasoning quickly.

Do not report a mismatch you have not actually confirmed by reading both sides.
A speculative cross-repo issue is expensive, because whoever reads it has to check
two repositories to dismiss it.

If the fix is suitable for an implementation agent, say so explicitly in the
issue body with a short line such as `Agent handoff: suitable after maintainer
adds agent-ready.` Do not add `agent-ready` yourself unless the repository's
maintainer has already approved that handoff.
