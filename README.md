# Claude Code Hermes DevOps Watchdog

This repository contains a Claude Code DevOps workflow for keeping a Hermes Agent server healthy.

Goal: set up a VPS-local watchdog that checks Hermes Agent, the messaging gateway, scheduled jobs, provider authentication, configured tools, and host health; performs only clearly safe repairs; and escalates risky changes to the operator.

## TL;DR

1. Install Hermes Agent on your VPS.
2. Install Claude Code on the same VPS, or on a trusted machine that can SSH into the VPS.
3. Open Claude Code and use this prompt:

```text
Configure yourself as the Hermes watchdog for this server. Start here: https://raw.githubusercontent.com/MichaelZelbel/hermes-claude-code-devops-watchdog/main/AGENT_START.md
```

That starter file contains the safety boundaries, dry-run checks, and local cron/systemd recommendations.

## Architecture note

The production watchdog should run locally on the VPS via cron or a systemd timer. Claude Code can help generate and test the scripts, but Claude Code `/schedule` and Claude Cloud Routines are remote cloud agents by default; they cannot access local VPS files, local services, `/opt/hermes`, `/opt/data`, or `systemctl --user` unless you explicitly add SSH/MCP/connectors.

Recommended default:

```text
VPS-local cron/systemd timer -> local check/repair scripts -> Telegram alert only when needed
```

See `docs/local-cron-telegram.md` for the recommended setup.

## Quick start

1. Clone or copy this repository onto the machine where Claude Code will run.
2. Make sure Claude Code can reach the Hermes VPS, either by running directly on the VPS or by SSHing into it.
3. Open this repository in Claude Code.
4. Start with a manual dry run before scheduling anything.

Suggested first prompt for Claude Code:

```text
You are setting up this repository as a Hermes DevOps watchdog.

Read README.md, CLAUDE.md, and hermes-devops-runbook.md first.

Then do a manual safe dry run of the quick repair workflow from prompts/hourly-quick-repair.md.

Important boundaries:
- Do not change firewall, SSH, Tailscale, secrets, auth, config, packages, or OS settings.
- Do not delete data.
- Do not update Hermes yet.
- Do not reveal tokens from /opt/data/.env, auth.json, provider configs, or chat logs.
- Only run read-only checks unless the Hermes messaging gateway is clearly down.
- If the installed Hermes gateway service is down, you may run `hermes gateway restart` once, then verify and report.
- If Hermes is only running as a foreground process or inside an interactive terminal, do not kill/restart it without operator approval.

After the dry run, report:
1. whether Hermes and the gateway are healthy,
2. which commands worked,
3. any warnings that should be documented,
4. whether this machine is suitable for scheduled watchdog runs,
5. the exact scheduled task prompt/frequency you recommend.
```

## Manual VPS validation

Before enabling a scheduled watchdog, verify the basic commands on the VPS:

```bash
hermes status
hermes doctor
hermes gateway status
hermes cron list
hermes model --help
hermes logs --since 1h
hermes logs errors --since 24h
ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'
df -h
df -i
free -h
uptime
```

Expected healthy signs:

- `hermes status` shows the expected model/provider and configured messaging platforms.
- `hermes doctor` has no critical failures for the configured deployment.
- `hermes gateway status` matches the intended gateway mode.
- The gateway process or installed service is running when Telegram/Discord/WhatsApp delivery is expected.
- Scheduled jobs are present when the operator expects cron jobs.
- Disk usage is comfortably below warning levels, ideally below 80%.
- Memory and load are not under sustained pressure.

## Recommended scheduling model

Use local cron or a systemd timer on the VPS as the default watchdog runner.

Recommended local jobs:

1. `quick-check.sh`
   - Frequency: every 5 minutes, or hourly if you prefer less noise.
   - Source prompt/policy: `prompts/hourly-quick-repair.md`.
   - Purpose: fast health check, safe gateway repair, Telegram incident report only when needed.

2. `deep-check.sh`
   - Frequency: every 6 hours.
   - Source prompt/policy: `prompts/six-hour-deep-check.md`.
   - Purpose: deeper Hermes, gateway, cron, provider auth, logs, disk/RAM health.

3. Optional `update-maintenance` run
   - Frequency: weekly or manual.
   - Source prompt/policy: `prompts/update-maintenance.md`.
   - Purpose: safe Hermes update flow with pre/post smoke tests and explicit rollback boundaries.
   - Do not auto-update unless the operator explicitly approves that policy.

## What about Claude Code `/schedule`?

Do not assume Claude Code scheduled tasks run on the VPS. Claude Code `/schedule` and Cloud Routines are remote agents unless you deliberately provide secure access to the VPS.

Use remote scheduled agents only for advanced setups such as:

- SSH from the remote agent into a restricted watchdog user,
- MCP/connectors that can safely run the local checks,
- a strongly authenticated HTTPS status endpoint.

For most users, local cron + Telegram is simpler, safer, and more reliable.

## Files

- `hermes-devops-runbook.md` — operational policy and escalation rules.
- `docs/local-cron-telegram.md` — recommended production architecture using local cron/systemd timer plus Telegram alerts.
- `prompts/hourly-quick-repair.md` — main quick scheduled prompt.
- `prompts/six-hour-deep-check.md` — deep scheduled prompt.
- `prompts/update-maintenance.md` — update prompt.
- `templates/claude-settings.conservative.example.json` — stricter permission template.
- `templates/claude-settings.autonomous-devops.example.json` — more autonomous template after the operator explicitly approves it.
- `templates/desktop-scheduled-task-skill.example.md` — optional Claude Code Desktop scheduled task SKILL.md wrapper.

## Safety principle

Claude Code may repair Hermes within narrowly scoped boundaries, but it must not silently perform destructive, security-sensitive, or broad system changes. Restarting an installed Hermes gateway service can be safe after evidence and verification. Deleting unknown files, rotating secrets, changing firewall/SSH, changing provider credentials, and major updates are not.
