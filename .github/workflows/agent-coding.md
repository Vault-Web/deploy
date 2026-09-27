---
description: Implements deploy issues labelled agent-ready as draft pull requests.
intent: Turn well-scoped deployment automation, Compose, script, and documentation issues into reviewable draft pull requests after a maintainer has explicitly approved agent work.

on:
  issues:
    types: [labeled]
  labels: [agent-ready]
  roles: [admin, maintainer, write]
  bots: ["vault-web-agents[bot]"]
  reaction: rocket
  skip-if-match:
    query: "is:pr is:open label:agent-managed"
    max: 3

permissions:
  contents: read
  issues: read
  pull-requests: read

timeout-minutes: 30
max-turns: 90
max-ai-credits: 350
max-daily-ai-credits: 700

concurrency:
  group: "agent-coding-${{ github.event.issue.number }}"

tools:
  bash: ["cat", "ls", "find", "grep", "head", "tail", "wc", "sort", "sed", "awk", "jq", "git", "docker", "gh"]
  github:
    mode: gh-proxy
    toolsets: [repos, issues, pull_requests]
    allowed-repos: ["vault-web/deploy"]
    min-integrity: approved
    trusted-users: ["vault-web-agents[bot]"]
    approval-labels: [agent-approved]

safe-outputs:
  report-failure-as-issue: false
  github-app:
    app-id: ${{ vars.VAULTWEB_AGENT_APP_ID }}
    private-key: ${{ secrets.VAULTWEB_AGENT_APP_KEY }}
  create-pull-request:
    max: 1
    title-prefix: "[agent] "
    labels: [agent-managed]
    draft: true
  add-comment:
    max: 1
    target: triggering

network:
  allowed: [defaults]
---

# Implement a Deploy Issue

An issue in `Vault-Web/deploy` was labelled `agent-ready`, either by a
maintainer or by a trusted project agent after maintainer approval. Implement it
as a focused draft pull request.

## First: make sure nobody else is working on it

Contributors come first. Before changing anything, check the issue and stop with
a short comment if any of these is true:

- the issue has an assignee;
- an open pull request already references the issue;
- someone has said they are working on it;
- the issue is labelled `good first issue`.

If you cannot read the issue body because it was written by someone outside the
project and has not been approved for agents, comment that a maintainer needs to
add `agent-approved` before you can work on it, and stop.

## What you may change

This repository owns deployment composition and operations glue:

- Docker Compose files and deployment scripts;
- concise operator-facing README updates;
- GitHub workflow automation in this repository;
- submodule pointers only when the issue explicitly asks for a deploy pin update.

Do not make source-code changes inside service submodules from this repository.
If a service code fix is needed, comment with the owning repository and stop so
the issue can be routed there.

## Implementation standard

- Keep the change scoped to the issue.
- Preserve the existing style and naming.
- Validate YAML and shell changes where practical.
- For Compose changes, run `docker compose -f docker-compose.deploy.yml config`
  when possible. If it cannot run because required local files or Docker are
  unavailable, say so in the pull request description.
- Keep docs professional, concise, and current. Avoid exhaustive implementation
  reference material.

## The pull request

Work on a branch named `agent/issue-<number>-<short-slug>`. Open a draft pull
request with a clear summary, the validation you ran, and any remaining manual
checks. Link the issue.
