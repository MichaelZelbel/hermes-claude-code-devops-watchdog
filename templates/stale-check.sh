#!/usr/bin/env bash
# ==============================================================================
# Hermes Watchdog: stale-code check (every ~5 min via cron, next to quick-check.sh).
#
# A gateway can be active in systemd, hold its connection to its messaging
# platform, and still answer every message with a traceback. That happens when
# the Hermes source is replaced under a running process: Python keeps the classes
# it already imported and compiles lazily imported modules fresh from the new
# files, so old objects meet new code. quick-check.sh cannot see it, because by
# every liveness signal the gateway is up.
#
# The test: a gateway whose main process started BEFORE the newest source file
# it runs from, or before its profile's config.yaml last changed, is running
# stale code or stale settings. One restart fixes it and is self-limiting: after
# the restart the process is newer than the files and this stays quiet until the
# next change.
#
# Since Hermes v0.21.4 (2026-09-21) `hermes update` restarts stale gateways
# itself, at update time. This check is the net for the rest: a source change by
# any other route (git pull, pip or uv, a hand edit), an update that crashed
# before its restart phase, a changed config.yaml, and gateways with no recorded
# commit. It never restarts on a guess: anything it cannot measure is "fine".
#
# Exit codes:
#   0  nothing stale, or cannot tell
#   10 restarted at least one gateway onto current code
#   11 a gateway is still stale or down after its restart: a person should look
#
# Overrides (env vars):
#   UNITS           systemd units to check, space-separated
#                   (default: hermes-gateway.service)
#   SYSTEMCTL_USER  1 = the units are systemd user services (default: 0)
#   HERMES_USER     unix user that owns the Hermes install (default: hermes)
#   HERMES_HOME     (default: /home/$HERMES_USER/.hermes)
#   HERMES_BIN      hermes CLI (default: /home/$HERMES_USER/.local/bin/hermes)
#   HERMES_SRC      the Hermes source tree; asked of `$HERMES_BIN --version` when unset
#   STALE_COOLDOWN  seconds between two staleness restarts of one unit (default: 3600)
#   SETTLE_SECONDS  wait after a restart before checking again (default: 15)
#   QUIET_RESTART   1 = ask the gateway not to announce its shutdown (default: 1)
#   DRY_RUN         1 = log what would be restarted, restart nothing (default: 0)
#   STATE_DIR       (default: /var/lib/hermes-watchdog/stale)
#   LOG_FILE        (default: /var/log/hermes-watchdog/stale.log)
# ==============================================================================
set -uo pipefail

UNITS="${UNITS:-hermes-gateway.service}"
SYSTEMCTL_USER="${SYSTEMCTL_USER:-0}"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/${HERMES_USER}/.hermes}"
HERMES_BIN="${HERMES_BIN:-/home/${HERMES_USER}/.local/bin/hermes}"
HERMES_SRC="${HERMES_SRC:-}"
STALE_COOLDOWN="${STALE_COOLDOWN:-3600}"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
QUIET_RESTART="${QUIET_RESTART:-1}"
DRY_RUN="${DRY_RUN:-0}"
STATE_DIR="${STATE_DIR:-/var/lib/hermes-watchdog/stale}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-watchdog/stale.log}"

SYSTEMCTL=(systemctl)
if [ "$SYSTEMCTL_USER" = "1" ]; then SYSTEMCTL+=(--user); fi

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s | %s\n' "$(ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# Where the gateway's Python code lives. HERMES_SRC wins. Otherwise ask Hermes:
# since v0.21.1 `hermes --version` prints "Install directory: <dir>", the folder
# above hermes_cli. Current installs make the CLI a /bin/sh launcher, so its
# first line names no interpreter. As root it asks as HERMES_USER, so no
# root-owned bytecode lands in the tree. Last, for an older install whose CLI is
# a Python console script, ask that interpreter where hermes_cli is.
detect_src() {
  if [ -n "$HERMES_SRC" ]; then printf '%s\n' "$HERMES_SRC"; return 0; fi
  [ -x "$HERMES_BIN" ] || return 1
  local d py as=()
  if [ "$(id -u)" = 0 ] && [ "$HERMES_USER" != root ] && command -v runuser >/dev/null 2>&1; then
    as=(runuser -u "$HERMES_USER" --)
  fi
  d="$(${as[@]+"${as[@]}"} env HERMES_HOME="$HERMES_HOME" timeout 30 "$HERMES_BIN" --version 2>/dev/null \
        | sed -n 's/^Install directory: //p' | head -n1)"
  if [ -n "$d" ] && [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  py="$(head -n1 "$HERMES_BIN" 2>/dev/null | sed -n 's/^#![[:space:]]*//p' | awk '{print $1}')"
  [ -n "$py" ] && [ -x "$py" ] || return 1
  "$py" -c 'import os, hermes_cli; print(os.path.dirname(os.path.dirname(os.path.abspath(hermes_cli.__file__))))' 2>/dev/null
}

# Newest mtime of any .py the gateway can import, in epoch seconds. Folders it
# never imports are pruned by NAME below the tree, never by absolute path, so a
# tree that itself sits inside a .venv (a pip install) is still read. They are
# pruned at all because a package manager once touched a .py under node_modules
# and every gateway on the host looked stale at once. A file dated in the future
# is skipped: no restart could ever make a process newer than it.
source_stamp() { # source_stamp <dir>
  local now; now="$(date +%s)"
  find "$1" -mindepth 1 \
      \( -type d \( -name venv -o -name .venv -o -name __pycache__ -o -name node_modules \
                   -o -name tests -o -name docs -o -name website -o -name .git -o -name .hermes-runtime \) -prune \) \
      -o \( -type f -name '*.py' -printf '%T@\n' \) 2>/dev/null \
    | cut -d. -f1 | awk -v now="$now" '$1 <= now' | sort -rn | head -n1
}

# When the unit's main process began, from its age, so no date string is parsed.
unit_start_stamp() { # unit_start_stamp <unit>
  local pid el
  pid="$("${SYSTEMCTL[@]}" show -p MainPID --value "$1" 2>/dev/null)"
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  el="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$el" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - el ))
}

# hermes-gateway.service is the default profile, hermes-gateway-<name>.service is profiles/<name>.
profile_home() { # profile_home <unit>
  case "$1" in
    hermes-gateway.service) printf '%s\n' "$HERMES_HOME" ;;
    hermes-gateway-*.service) local n="${1#hermes-gateway-}"; printf '%s\n' "$HERMES_HOME/profiles/${n%.service}" ;;
    *) return 1 ;;
  esac
}

# A gateway reads its settings once, at start, exactly as it imports its code once.
config_stamp() { # config_stamp <unit>
  local h; h="$(profile_home "$1")" || return 1
  stat -c %Y "$h/config.yaml" 2>/dev/null
}

# 0 = stale (started before the code or the settings it runs), 1 = fine, 2 = cannot tell.
unit_is_stale() { # unit_is_stale <unit> <src_stamp>
  local src="$2" proc cfg now
  [ -n "$src" ] || return 2
  proc="$(unit_start_stamp "$1")" || return 2
  [ -n "$proc" ] || return 2
  now="$(date +%s)"
  cfg="$(config_stamp "$1" || true)"
  if [ -n "$cfg" ] && [ "$cfg" -le "$now" ] && [ "$cfg" -gt "$src" ]; then src="$cfg"; fi
  [ "$proc" -lt "$src" ]
}

# A restart that does not announce itself. Hermes reads .drain_request.json in
# the profile home when it shuts down; suppress_notification=true skips the
# home-channel shutdown broadcast. The epoch is the machine's instantiation
# (boot id + PID 1 start), as Hermes writes it, so a leftover copy can never park
# a gateway after a reboot. Stop, remove the marker, start: a fresh gateway that
# found the marker would report itself as draining.
quiet_restart() { # quiet_restart <unit>
  local unit="$1" home marker epoch
  if [ "$QUIET_RESTART" = "1" ] && home="$(profile_home "$unit")" && [ -d "$home" ]; then
    marker="$home/.drain_request.json"
    epoch="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null):$(awk '{print $22}' /proc/1/stat 2>/dev/null)"
    if printf '{"action": "drain", "requested_at": "%s", "principal": "hermes-watchdog-stale-check", "epoch": "%s", "suppress_notification": true}\n' \
         "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" "$epoch" > "$marker" 2>/dev/null; then
      chown "$HERMES_USER:$HERMES_USER" "$marker" 2>/dev/null || true
      "${SYSTEMCTL[@]}" stop "$unit" >> "$LOG_FILE" 2>&1 || true
      rm -f "$marker"
      "${SYSTEMCTL[@]}" start "$unit" >> "$LOG_FILE" 2>&1 || true
      return 0
    fi
  fi
  "${SYSTEMCTL[@]}" restart "$unit" >> "$LOG_FILE" 2>&1 || true
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" 2>/dev/null || true
  # One sweep at a time: a sweep right after an upgrade can outlast the cron
  # interval, and two sweeps would then restart the same gateway twice.
  { exec 9>"$STATE_DIR/.lock"; } 2>/dev/null || { log "cannot write to $STATE_DIR; not restarting anything"; return 0; }
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then return 0; fi

  local src_dir src rc=0 unit last now s
  src_dir="$(detect_src)" || src_dir=""
  if [ -z "$src_dir" ] || [ ! -d "$src_dir" ]; then
    log "cannot find the Hermes source; set HERMES_SRC. Not restarting anything"; return 0
  fi
  src="$(source_stamp "$src_dir")"
  if [ -z "$src" ]; then
    log "no usable .py files under $src_dir; set HERMES_SRC. Not restarting anything"; return 0
  fi

  for unit in $UNITS; do
    "${SYSTEMCTL[@]}" is-active --quiet "$unit" || continue   # a dead gateway is quick-check.sh's job
    unit_is_stale "$unit" "$src"; s=$?
    [ "$s" -eq 0 ] || continue
    now="$(date +%s)"
    last="$(cat "$STATE_DIR/$unit.last" 2>/dev/null || echo 0)"
    if [ $(( now - last )) -lt "$STALE_COOLDOWN" ]; then
      log "$unit is stale; restarted for that $(( (now - last) / 60 ))m ago, leaving it"; continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY RUN: $unit started before the code or settings it runs; would restart it"; continue
    fi
    printf '%s' "$now" > "$STATE_DIR/$unit.last" 2>/dev/null \
      || { log "cannot record the restart time for $unit; not restarting it"; continue; }
    log "$unit started before the code or settings it runs; restarting"
    quiet_restart "$unit"
    sleep "$SETTLE_SECONDS"
    unit_is_stale "$unit" "$src"; s=$?
    if "${SYSTEMCTL[@]}" is-active --quiet "$unit" && [ "$s" -eq 1 ]; then
      log "$unit restarted onto current code"
      [ "$rc" -eq 0 ] && rc=10
    else
      log "$unit still stale or down after a restart; a person should look"
      rc=11
    fi
  done
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; exit $?; fi
