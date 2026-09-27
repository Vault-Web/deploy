---
description: Weekly repository audit that files at most two high-confidence issues, or none.
intent: Find the small number of genuinely actionable problems in the repository each week — security gaps, correctness bugs, untested critical paths — and file them as issues only when they are strong enough to be worth a maintainer's attention.

on:
  schedule: every 14 days
  workflow_dispatch:
  skip-if-match:
    query: "is:issue is:open label:agent-audit"
    max: 4

permissions:
  contents: read
  issues: read
  pull-requests: read

timeout-minutes: 25
max-turns: 80
max-ai-credits: 150
max-daily-ai-credits: 400

concurrency:
  group: "agent-weekly-audit"

tools:
  github:
    mode: gh-proxy
    toolsets: [repos, issues, pull_requests]
    allowed-repos: ["vault-web/deploy"]
    min-integrity: approved

safe-outputs:
  report-failure-as-issue: false
  create-issue:
    max: 2
    title-prefix: "[audit] "
    labels: [agent-audit, found-from-deploy, deploy-drift]

network:
  allowed: [defaults]
---

# Weekly Repository Audit

Audit `Vault-Web/deploy` — the deployment repository holding Docker Compose,
submodule pins, and automation scripts — for work that is genuinely worth doing.

## Before proposing anything

Search the existing issues first. Look at:

- open issues, including those labelled `agent-audit` from your previous runs
- issues closed in the last few months, so you do not re-file something that was
  rejected or already fixed
- recent commits and merged pull requests, to see whether a problem you spotted
  is already being addressed

A finding that duplicates existing work is worse than no finding at all.

## What to look for

- **Configuration drift** — Compose services, ports, volumes, or environment
  variables that no longer match what the services actually expect.
- **Stale submodule pins** — a service pinned far behind its current main,
  especially when the gap includes security fixes.
- **Secrets and defaults** — credentials committed to the repository, insecure
  defaults that would reach production.
- **Container hygiene** — unpinned base images, unnecessary root, missing
  healthchecks.
- **Scripts** — automation that fails silently or assumes state it does not check.

## The hard rule

Create **at most two** issues, and create **none** when nothing meets the bar.
An empty run is a successful run. Do not pad the output to reach two. Do not file
a finding you cannot back with a specific file and a specific consequence.

If you have nothing strong enough, emit `noop`.

## Issue format

Each issue states the problem, the file and line, why it matters, and what a fix
would involve. Keep it short enough that a maintainer can judge it in a minute.
Issues from this deploy audit are labelled `found-from-deploy` and `deploy-drift`
so they can be routed and filtered separately from ordinary repository work.
