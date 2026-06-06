#!/usr/bin/env bash
# ==============================================================================
# Hermes Watchdog — quick health check (every ~5 min via cron/systemd timer).
#
# Activity-INDEPENDENT liveness check. An idle gateway is healthy — do not
# treat log silence as failure. This file is a drop-in replacement for the
# legacy /opt/hermes-watchdog/quick-check.sh that used `agent.log` mtime as a
# liveness signal and restarted healthy idle gateways every ~6 h.
#
# Quiet when healthy; restart the gateway only when a real liveness signal
# is broken. Notifications/Telegram are emitted by sibling scripts, not here.
#
# Exit codes:
#   0  healthy (or suspicious-but-not-yet-degraded; we wait for re-check)
#   10 degraded — gateway restart attempted
#
# Overrides (env vars; sane defaults match the kit's recommended layout):
#   SERVICE         systemd unit name (default: hermes-gateway.service)
#   SYSTEMCTL_USER  pass --user to systemctl? (set to 1 if Hermes was
#                   installed as a systemd user service for HERMES_USER)
#   HERMES_USER     unix user that owns the Hermes install (default: hermes)
#   HERMES_HOME     HERMES_HOME for the hermes user (default: ~hermes/.hermes)
#   HERMES_BIN      hermes CLI path (default: ~hermes/.local/bin/hermes)
#   AGENT_LOG       agent log path (default: $HERMES_HOME/logs/agent.log)
#   GRACE_SECONDS   warm-up grace after service start (default: 120)
#   RECHECK_SLEEP   re-check delay after a failed probe (default: 10)
#   PROBE_TIMEOUT   bound on `hermes gateway status` (default: 15)
#   LOG_FILE        watchdog log (default: /var/log/hermes-watchdog/quick.log)
# ==============================================================================

set -uo pipefail

SERVICE="${SERVICE:-hermes-gateway.service}"
SYSTEMCTL_USER="${SYSTEMCTL_USER:-0}"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/${HERMES_USER}/.hermes}"
HERMES_BIN="${HERMES_BIN:-/home/${HERMES_USER}/.local/bin/hermes}"
AGENT_LOG="${AGENT_LOG:-${HERMES_HOME}/logs/agent.log}"
GRACE_SECONDS="${GRACE_SECONDS:-120}"
RECHECK_SLEEP="${RECHECK_SLEEP:-10}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-15}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-watchdog/quick.log}"
STATE_DIR="${STATE_DIR:-/var/lib/hermes-watchdog}"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" 2>/dev/null || true

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }

# Build the systemctl prefix once so every call uses the same scope.
SYSTEMCTL=(systemctl)
if [ "$SYSTEMCTL_USER" = "1" ]; then
  SYSTEMCTL+=(--user)
fi

# ------------------------------------------------------------------------------
# Probe 1: systemd unit must be active.
# This is the ONLY check that fires regardless of warm-up grace — if the unit
# is not active the gateway is definitely not running.
# ------------------------------------------------------------------------------
if ! "${SYSTEMCTL[@]}" is-active --quiet "$SERVICE"; then
  log "→ DEGRADED (systemctl: $SERVICE not active)"
  log "restarting $SERVICE"
  "${SYSTEMCTL[@]}" restart "$SERVICE" >> "$LOG_FILE" 2>&1 || \
    log "restart command failed"
  exit 10
fi

# ------------------------------------------------------------------------------
# Probe 2: warm-up grace.
# A gateway that started <GRACE_SECONDS ago may still be establishing its
# Telegram poll connection. Don't false-alarm during reconnect blips.
# ------------------------------------------------------------------------------
active_ts="$("${SYSTEMCTL[@]}" show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null)"
if [ -n "$active_ts" ]; then
  active_epoch="$(date -d "$active_ts" +%s 2>/dev/null || echo 0)"
else
  active_epoch=0
fi
now_epoch="$(date +%s)"
if [ "$active_epoch" -gt 0 ]; then
  uptime_s=$((now_epoch - active_epoch))
else
  uptime_s=999999
fi

if [ "$uptime_s" -ge 0 ] && [ "$uptime_s" -lt "$GRACE_SECONDS" ]; then
  log "→ HEALTHY (warm-up grace, uptime=${uptime_s}s < ${GRACE_SECONDS}s)"
  exit 0
fi

# ------------------------------------------------------------------------------
# Probe A (advisory): `hermes gateway status` exit code.
# Run as the hermes user with HERMES_HOME set. Bounded by `timeout`.
#
# On Hermes versions where `gateway status` is a real liveness probe and
# returns non-zero when the gateway is hung, this catches degradation early.
# On versions where it is a thin systemd state echo, it always returns 0
# when the unit is active (which we already verified above) — harmless.
# Therefore Option A is used as an EARLY-DEGRADE trigger only; success here
# does NOT short-circuit Probes B + C below, because A may be circular.
# ------------------------------------------------------------------------------
probe_a_status() {
  if [ ! -x "$HERMES_BIN" ]; then
    return 0  # CLI missing → skip Option A; rely on B+C
  fi

  # If we are already running as the hermes user, no sudo hop needed.
  if [ "$(id -un)" = "$HERMES_USER" ]; then
    HERMES_HOME="$HERMES_HOME" timeout "$PROBE_TIMEOUT" \
      "$HERMES_BIN" gateway status >/dev/null 2>&1
    return $?
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    return 0  # no sudo → skip Option A; rely on B+C
  fi

  # Pre-flight: can we hop to $HERMES_USER without a password prompt? If not
  # (e.g. non-root operator with no NOPASSWD entry), skip Option A rather
  # than misread "sudo refused" as "gateway unhealthy".
  if ! sudo -n -u "$HERMES_USER" true >/dev/null 2>&1; then
    return 0
  fi

  sudo -n -u "$HERMES_USER" \
       HERMES_HOME="$HERMES_HOME" \
       timeout "$PROBE_TIMEOUT" \
       "$HERMES_BIN" gateway status >/dev/null 2>&1
}

if ! probe_a_status; then
  log "probe-A: hermes gateway status returned non-zero"
  a_failed=1
else
  a_failed=0
fi

# ------------------------------------------------------------------------------
# Probe B (independent): gateway PID holds an outbound :443 connection.
# A healthy gateway in polling mode always holds at least one ESTABLISHED
# TCP connection to a remote :443 (Telegram API, or the messaging platform
# in use). This is activity-independent — works whether the gateway is busy
# or idle. We deliberately do NOT hard-code Telegram IP ranges; ranges drift.
# ------------------------------------------------------------------------------
probe_b_connection() {
  local pid
  # Match the long-form invocation Hermes writes into the unit; fall back to
  # any `hermes` process owned by HERMES_USER if the pattern misses.
  pid="$(pgrep -u "$HERMES_USER" -f "gateway run" | head -1)"
  if [ -z "$pid" ]; then
    pid="$(pgrep -u "$HERMES_USER" -x hermes | head -1)"
  fi
  [ -n "$pid" ] || return 1
  # `ss -p` includes `pid=NNN,` in the process column when run as root.
  ss -tnp 2>/dev/null | grep -q "pid=${pid},.*:443"
}

# ------------------------------------------------------------------------------
# Probe C (independent): "Connected to Telegram" logged after last service start.
# Surviving check from the legacy script — the platform-handshake signal.
# Conservative parse: if we can't determine the timestamp, return ok rather
# than falsely declaring degraded.
# ------------------------------------------------------------------------------
probe_c_log() {
  [ -f "$AGENT_LOG" ] || return 0  # no log yet → don't false-alarm
  [ "$active_epoch" -gt 0 ] || return 0  # can't compare timestamps → skip

  # Look in the live log AND the most recent rotation (long-uptime idle
  # gateways legitimately have the handshake line in agent.log.1).
  local sources=("$AGENT_LOG")
  [ -f "${AGENT_LOG}.1" ] && sources+=("${AGENT_LOG}.1")

  local last_match
  last_match="$(grep -hF "Connected to Telegram" "${sources[@]}" 2>/dev/null | tail -1)"
  [ -n "$last_match" ] || return 1

  # Best-effort: Hermes log lines start with an ISO-ish timestamp. Try to
  # parse the first two whitespace tokens as a date; if we can't, assume the
  # match is recent (conservative).
  local match_iso match_epoch
  match_iso="$(printf '%s\n' "$last_match" | awk '{print $1" "$2}')"
  match_epoch="$(date -d "$match_iso" +%s 2>/dev/null)" || return 0
  [ -n "$match_epoch" ] || return 0
  [ "$match_epoch" -ge "$active_epoch" ]
}

run_independent_probes() {
  # Both B and C must pass for the independent signal to read healthy.
  probe_b_connection && probe_c_log
}

if [ "$a_failed" -eq 1 ]; then
  # Option A actively said unhealthy. Skip B+C and treat as degraded —
  # but still re-check once to avoid bouncing on a transient blip.
  sleep "$RECHECK_SLEEP"
  if probe_a_status && run_independent_probes; then
    log "→ HEALTHY (recovered after re-check; probe-A blip)"
    exit 0
  fi
  log "→ DEGRADED (probe-A failed twice; restarting $SERVICE)"
  "${SYSTEMCTL[@]}" restart "$SERVICE" >> "$LOG_FILE" 2>&1 || \
    log "restart command failed"
  exit 10
fi

if run_independent_probes; then
  log "→ HEALTHY (uptime=${uptime_s}s)"
  exit 0
fi

# Single in-tick re-check: a poll-cycle blip can briefly drop the :443
# connection. Wait RECHECK_SLEEP and probe once more before restarting.
sleep "$RECHECK_SLEEP"
if run_independent_probes; then
  log "→ HEALTHY (recovered after re-check; independent-probe blip)"
  exit 0
fi

log "→ DEGRADED (independent probes failed twice; restarting $SERVICE)"
"${SYSTEMCTL[@]}" restart "$SERVICE" >> "$LOG_FILE" 2>&1 || \
  log "restart command failed"
exit 10
