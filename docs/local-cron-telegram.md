# Local Cron + Telegram Watchdog

This is the recommended production architecture for a VPS-local Hermes watchdog.

## Why local cron?

Claude Code `/schedule` and Claude Cloud Routines run remote agents in Anthropic's cloud. They do not automatically run on the VPS and cannot access local files, local services, local environment variables, `/opt/hermes`, `/opt/data`, `systemctl --user`, or `hermes gateway status` unless you deliberately provide a connector such as SSH or MCP.

For a watchdog whose job is to repair a local Hermes gateway, the safest default is therefore:

```text
local cron/systemd timer on the VPS
  -> local check/repair scripts
  -> Telegram notification only when something meaningful happens
```

Telegram works well because it provides phone notifications without giving a remote cloud agent SSH access to the VPS.

## Recommended layout

Example paths:

```text
/opt/hermes-watchdog/
  quick-check.sh
  restart-gateway.sh
  deep-check.sh
  notify-telegram.sh
  logs/
```

Use whichever directory is appropriate for your server, but keep scripts readable and auditable.

A reference `quick-check.sh` implementation ships in this repository at `templates/quick-check.sh`. Copy it to `/opt/hermes-watchdog/quick-check.sh` (or wherever your layout puts it) and override the documented env vars as needed.

## Liveness signals — avoid the "stale log = restart" trap

The single biggest mistake in homemade Hermes watchdogs is treating `agent.log` mtime (or any "log freshness" check) as a liveness signal. It is not. A healthy Hermes that has no chat traffic for a few hours legitimately writes nothing to `agent.log`. A watchdog that restarts on log staleness will kick the gateway every ~6 hours during idle periods — observed live: 135 spurious restarts in one 5-week window, 100% with reason `agent.log not written in over 6h`, zero caused by an actual service failure.

The Python gateway exposes no HTTP port, so an HTTP `/health` check is also not an option. Use activity-INDEPENDENT signals instead:

1. `systemctl is-active <unit>` — must be active.
2. `hermes gateway status` exit code — only if it is a real probe on the installed Hermes version, not a thin systemd state echo (which would be circular).
3. PID-bound outbound `:443` check — a healthy gateway in polling mode always holds at least one ESTABLISHED TCP connection to its messaging platform. Resolve the gateway PID, then check `ss -tnp` for `pid=NNN,...:443`. Do NOT hard-code Telegram IP ranges (149.154.x, 91.108.x) — they drift; the `:443` + PID match is the durable signal.
4. "Connected to Telegram" (or analogous handshake line) present in `agent.log*` with a timestamp at or after the last service `ActiveEnterTimestamp` — surviving from a long-uptime idle gateway often means looking in `agent.log.1` after rotation, not just the live file.

Apply a startup grace period (~120 s) so a mid-reconnect blip during warm-up does not false-alarm, and re-check once (sleep ~10 s, probe again) before declaring degraded. The shipped `templates/quick-check.sh` implements all of this.

## Environment file

Store notification secrets outside the repository, for example:

```bash
sudo install -d -m 700 /etc/hermes-watchdog
sudoedit /etc/hermes-watchdog/env
sudo chmod 600 /etc/hermes-watchdog/env
```

Example variables:

```bash
TELEGRAM_BOT_TOKEN="***"
TELEGRAM_CHAT_ID="..."
```

Do not commit tokens, chat IDs, private hostnames, or production-specific config to this repository.

## Minimal notifier shape

`notify-telegram.sh` should send a concise message and fail closed if notification variables are missing.

Example behavior:

```bash
./notify-telegram.sh "Hermes watchdog: gateway was restarted and is healthy again."
```

Implementation can use Telegram's `sendMessage` endpoint, but keep the token in `/etc/hermes-watchdog/env`, not in the script.

## Cron shape

Start conservatively:

```cron
# quick check every 5 minutes
*/5 * * * * /opt/hermes-watchdog/quick-check.sh >> /opt/hermes-watchdog/logs/quick-check.log 2>&1

# deeper check every 6 hours
0 */6 * * * /opt/hermes-watchdog/deep-check.sh >> /opt/hermes-watchdog/logs/deep-check.log 2>&1
```

The quick check should be quiet when healthy. Notify only when:

- a repair was performed,
- repair failed,
- an approval is needed,
- disk/RAM/load crosses serious thresholds,
- Hermes gateway is down or unreachable after one restart attempt,
- provider auth or routing appears broken.

## Safety boundaries

Local cron may perform only pre-approved safe actions:

- run read-only `hermes status`, `hermes doctor`, `hermes gateway status`, `hermes cron list`, and log checks,
- restart an installed Hermes gateway service once via `hermes gateway restart` if clearly down,
- report evidence to the operator,
- clean only its own temporary files.

Cron should not:

- change config or credentials,
- rotate tokens,
- alter allowed users/channels/topics,
- install packages,
- update Hermes,
- reboot the server,
- delete Hermes state, memory, sessions, backups, or logs.

## systemd timer alternative

If you prefer systemd timers, create a dedicated service and timer for each check. Keep the unit restricted and point it at an auditable shell script. Use `systemctl --user` only when Hermes is intentionally installed as that user's service; otherwise use system units or cron according to your deployment.

## Notification policy

Do not spam healthy runs. A good policy is:

- incident and repair messages immediately,
- approval requests immediately,
- optional daily summary,
- no message for routine healthy checks.
