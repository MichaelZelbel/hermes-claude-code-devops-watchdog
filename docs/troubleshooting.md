# Troubleshooting

## Claude Code terminal connection closed unexpectedly

If the terminal running Claude Code disconnects, first determine what failed:

1. Did the VPS stay healthy?
   - `uptime`
   - `free -h`
   - `df -h`
   - `journalctl -k --since '2 hours ago' --no-pager | grep -Ei 'oom|killed process|segfault|out of memory'`

2. Did SSH or the web terminal disconnect?
   - `journalctl -u ssh --since '2 hours ago' --no-pager`
   - If using a provider browser console, retry over normal SSH. Browser consoles are more fragile than SSH.

3. Did Claude Code exit, or is it still running?
   - `ps aux | grep -Ei '[c]laude|[n]ode.*claude'`

4. Did Hermes itself stay healthy?
   - `hermes status`
   - `hermes doctor`
   - `hermes gateway status`
   - `ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'`

Recommended prevention:

- Run Claude Code inside `tmux` or `screen`, not directly in a provider web terminal.
- Prefer running the watchdog as the same OS user that owns the Hermes installation and data directory.
- Ensure the Hermes CLI is on that user's `PATH`, or use the absolute CLI path.
- If using a user service from another account, set `XDG_RUNTIME_DIR=/run/user/<uid>` correctly.

Example tmux flow:

```bash
tmux new -s hermes-watchdog
# run Claude Code inside tmux

# if disconnected later:
tmux attach -t hermes-watchdog
```

If Claude Code lost its context, restart the dry run from `AGENT_START.md` and mention what step disconnected.

## Gateway is down

- Check `hermes gateway status`.
- Read recent Hermes logs and errors.
- Check whether the gateway is managed by Hermes service, systemd, tmux, Docker/foreground, or another supervisor.
- If it is an installed Hermes-managed service, restart once with `hermes gateway restart`.
- Re-check gateway status and logs.
- Escalate if the restart does not repair it or if the gateway is a foreground/interactive process.

## Provider/model auth is broken

- Run `hermes status` and `hermes doctor`.
- Redact all tokens and credential paths in reports.
- Do not run `hermes login`, `hermes logout`, `hermes auth`, or `hermes model` without operator approval.
- Ask the operator for the preferred provider/model action.

## Scheduled jobs are missing or failing

- Run `hermes cron list`.
- Check recent Hermes logs and errors.
- Do not create/update/remove jobs without operator approval unless the operator has pre-approved a site-specific policy.

## Disk is full

- Check `df -h` and `df -i`.
- Identify large logs/caches read-only first.
- Vacuum systemd journal only when it is clearly the cause and the runbook allows it.
- Never delete unknown Hermes state, sessions, credentials, chat logs, memories, backups, repositories, or databases.
