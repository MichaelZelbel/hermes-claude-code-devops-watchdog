# Prompt: Hermes Six-Hour Deep Check

You are Claude Code acting as the operator's DevOps agent for Hermes.

Read and follow this runbook first:

`hermes-devops-runbook.md`

## Task

Run a deeper health check every six hours. Repair safe issues. Escalate risky ones.

## Required checks

### Host health

Run:

- `df -h`
- `df -i`
- `free -h`
- `uptime`
- `journalctl --disk-usage` if available.

Classify disk, inode, memory, swap, and load health using the runbook thresholds.

### Hermes CLI and config summary

Run:

- `hermes version`
- `hermes status`
- `hermes doctor`

Record expected provider/model/platform status. Redact secrets and do not print tokens.

### Gateway health

Run:

- `hermes gateway status`
- `hermes logs --since 6h`
- `hermes logs errors --since 24h`
- `ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'`

Look for repeated restarts, crashes, uncaught exceptions, auth problems, dependency errors, delivery failures, and OOM hints.

### Scheduled jobs and integrations

Run if available and relevant:

- `hermes cron list`
- `hermes webhook list`
- `hermes mcp list`
- `hermes tools list`

Do not create, update, pause, resume, remove, or run jobs without operator approval unless a site-specific policy explicitly allows it.

### Provider auth and API health

Use `hermes status` and `hermes doctor` as the primary checks. If a provider is unhealthy:

- capture the redacted error,
- do not run login/logout/auth/model changes without approval,
- ask the operator for the preferred credential/provider action.

## Auto-repair

Use the safe auto-repair rules from the runbook:

- Gateway restart is allowed only when needed and only for an installed Hermes-managed gateway service.
- Conservative journal vacuum is allowed only under critical disk pressure when logs are clearly the cause.
- Dependency fixes are approval-only unless a site-specific policy explicitly allows them.
- Updates are approval-only unless a site-specific automatic update policy explicitly allows them.

## Output rules

Use the runbook reporting format when there is an incident, repair, warning, or approval request.

For healthy routine runs, write a local concise summary and avoid operator spam unless a periodic summary was requested.
