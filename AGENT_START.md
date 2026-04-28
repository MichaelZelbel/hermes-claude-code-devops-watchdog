# Agent Start: Hermes Watchdog

Use this file as the starting point when asking Claude Code to configure itself as a watchdog for a Hermes Agent server.

## Goal

Configure Claude Code as a safe DevOps watchdog for Hermes Agent on this server.

Claude Code should help configure local VPS checks that periodically verify Hermes health, messaging gateway health, scheduled jobs, provider authentication, and host pressure; perform only clearly safe repairs; and escalate risky changes to the operator.

## First steps

1. Read these files in this repository:
   - `README.md`
   - `CLAUDE.md`
   - `hermes-devops-runbook.md`
   - `docs/local-cron-telegram.md`
   - `prompts/hourly-quick-repair.md`

2. Confirm where Claude Code is running:
   - directly on the Hermes VPS, or
   - on another trusted machine that can SSH into the VPS.

3. Identify the Hermes installation and data paths without revealing secrets. Common paths:
   - `/opt/hermes`
   - `/opt/data`
   - `~/.hermes`

4. Run a manual dry run of the quick repair workflow.

5. If the dry run succeeds, propose a local cron or systemd timer setup. Do not use Claude Code `/schedule` as the default runner, because scheduled Claude Code agents are remote by default and cannot access this VPS without an explicit connector such as SSH or MCP.

## Safety boundaries

Do not do any of these without explicit operator approval:

- Change firewall, SSH, Tailscale, public exposure, or auth settings.
- Rotate, reveal, or copy secrets/tokens.
- Delete data, sessions, memories, logs, backups, or provider auth files.
- Install/remove OS packages.
- Reboot the server.
- Update Hermes.
- Change Hermes config, model/provider defaults, tool permissions, platform tokens, cron jobs, webhooks, or MCP servers.

Read-only checks are allowed.

If the Hermes messaging gateway is clearly down and Hermes is installed as a managed service, Claude Code may restart only the gateway once:

```bash
hermes gateway restart
```

After restarting, verify the gateway and report what happened.

If Hermes is running as a foreground process, inside tmux/screen, Docker, or an interactive terminal, do not kill or restart that process without operator approval. Collect evidence and ask first.

## Manual dry-run checks

Run these checks first:

```bash
hermes status
hermes doctor
hermes gateway status
hermes cron list
hermes logs --since 1h
hermes logs errors --since 24h
ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'
df -h
df -i
free -h
uptime
```

Do not print secrets from `.env`, `auth.json`, provider credential files, Telegram tokens, or chat transcripts.

## Report back

After the dry run, report:

1. whether Hermes and the messaging gateway are healthy,
2. which commands worked,
3. any warnings or blockers,
4. whether this environment is suitable for scheduled watchdog runs,
5. which schedule you recommend.

## Recommended local schedule

Start conservatively with local cron or a systemd timer:

- every 5 minutes, or hourly: quick health check and safe gateway repair workflow,
- every 6 hours: deeper Hermes/host/provider/cron/log check,
- weekly or manual: update maintenance check.

Every scheduled task must be quiet when healthy and notify the operator only for a repair, incident, or approval request.
