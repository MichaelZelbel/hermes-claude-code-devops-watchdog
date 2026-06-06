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

## Watchdog auto-restarts a healthy idle gateway every ~6 hours

Symptom: `journalctl` and the watchdog log (`/var/log/hermes-watchdog/quick.log` or equivalent) show frequent restarts of `hermes-gateway.service` with reason `agent.log not written in over 6h` or similar. The gateway itself is fine (`systemctl show -p NRestarts` is `0` or low; the process has never crashed on its own).

Root cause: the watchdog is using `agent.log` mtime / file age as a liveness signal. It is not one. An idle Hermes with no chat traffic writes nothing to `agent.log` for hours at a time and is still perfectly healthy. The watchdog is repeatedly kicking a healthy gateway.

Fix: replace the offending `quick-check.sh` with the reference implementation at `templates/quick-check.sh` in this repository, or remove the mtime block from your local script and rely on the activity-independent signals documented in `docs/local-cron-telegram.md` (`systemctl is-active`, `hermes gateway status` exit code, PID-bound `:443` connection check, "Connected to Telegram" log presence after the last service start). Apply a ~120 s warm-up grace period and re-check transient probe failures once before restarting.

## Gateway restarts end in SIGKILL (status=9/KILL)

Symptom: `journalctl -u hermes-gateway` shows lines like:

```
hermes-gateway.service: State 'stop-sigterm' timed out. Killing.
hermes-gateway.service: Main process exited, code=killed, status=9/KILL
```

every time the gateway is restarted (manually, by `hermes gateway restart`, or by the watchdog). The gateway is not honoring SIGTERM within `TimeoutStopSec` (default 30 s) and systemd is escalating to SIGKILL.

Impact: restarts are ungraceful. In-flight work (poll cycles, message dispatch, tool calls) is terminated mid-flight rather than drained.

Workaround until upstream addresses signal handling: raise `TimeoutStopSec` in the unit file so a clean drain has more headroom. For a system unit at `/etc/systemd/system/hermes-gateway.service.d/timeout.conf` (drop-in override, preferred over editing the upstream unit):

```ini
[Service]
TimeoutStopSec=120
```

For a user unit, use `~/.config/systemd/user/hermes-gateway.service.d/timeout.conf` and reload with `systemctl --user daemon-reload`.

This is a workaround, not a fix. The underlying issue is that `hermes gateway run` does not exit cleanly on SIGTERM. Track upstream Hermes Agent for resolution; once fixed, remove the drop-in.

## Agent stopped replying after self-modifying its config

Symptom: gateway is active, Telegram (or other messaging platform) accepts messages, but the
agent never produces a reply. Check Hermes logs for repeated lines like:

```
No callable tools remain after resolving explicit tool allowlist
(tools.allow: <id>); no registered tools matched.
```

Note: this is the log pattern observed on the reference system. The exact Hermes log line
may differ — verify on a live install.

Root cause: the agent may have set a `tools.allow` key in `~/.hermes/config.yaml` to an ID
that does not match any registered tool, resulting in an empty resolved toolset. Whether
Hermes `config.yaml` exposes this key is unconfirmed — check `hermes config` output.

Manual recovery:

1. Run `hermes config` to inspect the config. Look for a `tools.allow` key.
2. If present and containing invented tool IDs, edit `~/.hermes/config.yaml` and remove
   the `tools.allow` key (keep `tools.profile` if present).
3. Run `hermes gateway restart`.
4. Wait up to 25 s for warm-up, then check `hermes gateway status` and `hermes status`.

For a permanent automated guardrail that detects and reverses this within minutes, see
`docs/agent-self-config-guardrail.md`.
