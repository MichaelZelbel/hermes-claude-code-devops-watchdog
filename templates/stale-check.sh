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
# Run as root for a system unit, it never lets root touch the Hermes user's files
# or run the Hermes user's programs: the drain marker is written, and the hermes
# CLI is asked, AS that user (runuser). Root following a symlink the user planted
# in its own home, or running a program the user controls, would hand it root.
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
#   RUNUSER         command root uses to act as HERMES_USER (default: runuser)
#
# Sourcing this file defines its functions and runs nothing. It sets no shell
# options in the caller and defines no ts or log; its own logger is sc_log.
# ==============================================================================

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
RUNUSER="${RUNUSER:-runuser}"
# A malformed number must not skip the cooldown: "1h" in a test is an error, and
# an error there reads as "cooldown over", which would restart every tick.
case "$STALE_COOLDOWN" in ''|*[!0-9]*) STALE_COOLDOWN=3600 ;; esac
case "$SETTLE_SECONDS" in ''|*[!0-9]*) SETTLE_SECONDS=15 ;; esac

SYSTEMCTL=(systemctl)
if [ "$SYSTEMCTL_USER" = "1" ]; then SYSTEMCTL+=(--user); fi

sc_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
sc_log() { printf '%s | %s\n' "$(sc_ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# True when this process may act as HERMES_USER: it is that user, or it is root
# and can drop to it. Root that cannot drop acts on nothing of the user's.
can_be_hermes_user() {
  [ "$(id -u)" != 0 ] || [ "$HERMES_USER" = root ] || command -v "$RUNUSER" >/dev/null 2>&1
}

# Run a command as HERMES_USER (dropping from root when needed), from /, so a
# working directory the user cannot read (root's home, under cron) cannot fail it.
as_hermes_user() { # as_hermes_user <command...>
  can_be_hermes_user || return 1
  if [ "$(id -u)" = 0 ] && [ "$HERMES_USER" != root ]; then
    (cd / && "$RUNUSER" -u "$HERMES_USER" -- "$@")
  else
    (cd / && "$@")
  fi
}

# Where the gateway's Python code lives. HERMES_SRC wins. Otherwise ask Hermes:
# since v0.21.1 `hermes --version` prints "Install directory: <dir>", the folder
# above hermes_cli. Current installs make the CLI a /bin/sh launcher, so its
# first line names no interpreter. Last, for an older install whose CLI is a
# Python console script, ask that interpreter where hermes_cli is. Both run as
# HERMES_USER (its programs, its bytecode), never as root, and without this
# script's lock on fd 9, so nothing they leave running can hold it.
detect_src() {
  if [ -n "$HERMES_SRC" ]; then printf '%s\n' "$HERMES_SRC"; return 0; fi
  [ -x "$HERMES_BIN" ] || return 1
  can_be_hermes_user || return 1
  local d py
  d="$(as_hermes_user env HERMES_HOME="$HERMES_HOME" timeout 30 "$HERMES_BIN" --version 2>/dev/null 9>&- \
        | sed -n 's/^Install directory: //p' | head -n1)"
  if [ -n "$d" ] && [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  py="$(head -n1 "$HERMES_BIN" 2>/dev/null | sed -n 's/^#![[:space:]]*//p' | awk '{print $1}')"
  [ -n "$py" ] && [ -x "$py" ] || return 1
  as_hermes_user "$py" -c 'import os, hermes_cli; print(os.path.dirname(os.path.dirname(os.path.abspath(hermes_cli.__file__))))' 2>/dev/null 9>&-
}

# Newest mtime of any .py the gateway can import, in epoch seconds. Folders it
# never imports are pruned by NAME below the tree, never by absolute path, so a
# tree that itself sits inside a .venv (a pip install) is still read. They are
# pruned at all because a package manager once touched a .py under node_modules
# and every gateway on the host looked stale at once. A file dated in the future
# is skipped: no restart could ever make a process newer than it. -H follows the
# tree itself when it is a symlink (and nothing below it).
source_stamp() { # source_stamp <dir>
  [ -n "${1:-}" ] || return 1
  local now; now="$(date +%s)"
  find -H "$1" -mindepth 1 \
      \( -type d \( -name venv -o -name .venv -o -name __pycache__ -o -name node_modules \
                   -o -name tests -o -name docs -o -name website -o -name .git -o -name .hermes-runtime \) -prune \) \
      -o \( -type f -name '*.py' -printf '%T@\n' \) 2>/dev/null \
    | cut -d. -f1 | awk -v now="$now" '$1 <= now' | sort -rn | head -n1
}

# When the unit's main process began, from its age, so no date string is parsed.
unit_start_stamp() { # unit_start_stamp <unit>
  [ -n "${1:-}" ] || return 1
  local pid el
  pid="$("${SYSTEMCTL[@]}" show -p MainPID --value "$1" 2>/dev/null)"
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  el="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$el" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - el ))
}

# hermes-gateway.service is the default profile, hermes-gateway-<name>.service is profiles/<name>.
profile_home() { # profile_home <unit>
  case "${1:-}" in
    hermes-gateway.service) printf '%s\n' "$HERMES_HOME" ;;
    hermes-gateway-*.service) local n="${1#hermes-gateway-}"; printf '%s\n' "$HERMES_HOME/profiles/${n%.service}" ;;
    *) return 1 ;;
  esac
}

# A gateway reads its settings once, at start, exactly as it imports its code once.
config_stamp() { # config_stamp <unit>
  local h; h="$(profile_home "${1:-}")" || return 1
  stat -c %Y "$h/config.yaml" 2>/dev/null
}

# 0 = stale (started before the code or the settings it runs), 1 = fine, 2 = cannot tell.
unit_is_stale() { # unit_is_stale <unit> <src_stamp>
  local unit="${1:-}" src="${2:-}" proc cfg now
  [ -n "$unit" ] && [ -n "$src" ] || return 2
  proc="$(unit_start_stamp "$unit")" || return 2
  [ -n "$proc" ] || return 2
  now="$(date +%s)"
  cfg="$(config_stamp "$unit" || true)"
  if [ -n "$cfg" ] && [ "$cfg" -le "$now" ] && [ "$cfg" -gt "$src" ]; then src="$cfg"; fi
  [ "$proc" -lt "$src" ]
}

# A restart that does not announce itself. Hermes reads .drain_request.json in
# the profile home when it shuts down; suppress_notification=true skips the
# home-channel shutdown broadcast. The epoch is the machine's instantiation
# (boot id + PID 1 start), as Hermes writes it, so a leftover copy can never park
# a gateway after a reboot. Stop, remove the marker, start: a fresh gateway that
# found the marker would report itself as draining. The marker is written as
# HERMES_USER, never by root (see the header). A run killed between writing it
# and removing it removes it on the way out, and main removes one a SIGKILL left.
SC_PRINCIPAL=hermes-watchdog-stale-check
sc_marker=""
quiet_restart() { # quiet_restart <unit>
  local unit="${1:-}" home epoch traps
  [ -n "$unit" ] || return 1
  if [ "$QUIET_RESTART" = "1" ] && home="$(profile_home "$unit")" && [ -d "$home" ] && can_be_hermes_user; then
    sc_marker="$home/.drain_request.json"
    epoch="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null):$(awk '{print $22}' /proc/1/stat 2>/dev/null)"
    # shellcheck disable=SC2016  # "$1" belongs to the inner sh, which writes the file as HERMES_USER
    if printf '{"action": "drain", "requested_at": "%s", "principal": "%s", "epoch": "%s", "suppress_notification": true}\n' \
         "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" "$SC_PRINCIPAL" "$epoch" \
         | as_hermes_user sh -c 'cat > "$1"' sh "$sc_marker" 2>/dev/null; then
      traps="$(trap -p EXIT INT TERM HUP)"
      trap 'rm -f "$sc_marker"' EXIT
      trap 'rm -f "$sc_marker"; exit 143' INT TERM HUP
      "${SYSTEMCTL[@]}" stop "$unit" >> "$LOG_FILE" 2>&1 || true
      rm -f "$sc_marker"
      trap - EXIT INT TERM HUP
      eval "$traps"
      "${SYSTEMCTL[@]}" start "$unit" >> "$LOG_FILE" 2>&1 || true
      return 0
    fi
  fi
  "${SYSTEMCTL[@]}" restart "$unit" >> "$LOG_FILE" 2>&1 || true
}

# A marker this check wrote and a SIGKILL kept it from removing: the next start of
# that gateway would park as draining for up to an hour. Only a regular file with
# this check's own principal is removed; anyone else's marker is left alone.
remove_leftover_markers() {
  local unit m
  for unit in $UNITS; do
    m="$(profile_home "$unit")/.drain_request.json" || continue
    if [ -f "$m" ] && [ ! -L "$m" ] && grep -q "\"principal\": \"$SC_PRINCIPAL\"" "$m" 2>/dev/null; then
      rm -f "$m" && sc_log "removed a drain marker a killed run left for $unit"
    fi
  done
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" 2>/dev/null || true
  # A log that cannot be written must not stop the restart: every systemctl call
  # appends to it, and a failed redirection skips the command it belongs to.
  if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
    echo "stale-check: cannot write $LOG_FILE; logging nowhere" >&2
    LOG_FILE=/dev/null
  fi
  # One sweep at a time: a sweep right after an upgrade can outlast the cron
  # interval, and two sweeps would then restart the same gateway twice.
  if ! { exec 9>"$STATE_DIR/.lock"; } 2>/dev/null; then
    sc_log "cannot write to $STATE_DIR; not restarting anything"
    echo "stale-check: cannot write to $STATE_DIR; not restarting anything" >&2
    return 0
  fi
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then return 0; fi
  remove_leftover_markers

  local src_dir src rc=0 unit last now s
  src_dir="$(detect_src)" || src_dir=""
  if [ -z "$src_dir" ] || [ ! -d "$src_dir" ]; then
    sc_log "cannot find the Hermes source; set HERMES_SRC. Not restarting anything"; return 0
  fi
  src="$(source_stamp "$src_dir")"
  if [ -z "$src" ]; then
    sc_log "no usable .py files under $src_dir; set HERMES_SRC. Not restarting anything"; return 0
  fi

  for unit in $UNITS; do
    "${SYSTEMCTL[@]}" is-active --quiet "$unit" || continue   # a dead gateway is quick-check.sh's job
    unit_is_stale "$unit" "$src"; s=$?
    [ "$s" -eq 0 ] || continue
    now="$(date +%s)"
    last="$(cat "$STATE_DIR/$unit.last" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # A stamp from the future (a clock that was wrong) counts as expired, or it
    # would block every restart until the clock caught up.
    if [ "$last" -le "$now" ] && [ $(( now - last )) -lt "$STALE_COOLDOWN" ]; then
      sc_log "$unit is stale; restarted for that $(( (now - last) / 60 ))m ago, leaving it"; continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
      sc_log "DRY RUN: $unit started before the code or settings it runs; would restart it"; continue
    fi
    printf '%s' "$now" > "$STATE_DIR/$unit.last" 2>/dev/null \
      || { sc_log "cannot record the restart time for $unit; not restarting it"; continue; }
    sc_log "$unit started before the code or settings it runs; restarting"
    quiet_restart "$unit"
    sleep "$SETTLE_SECONDS"
    unit_is_stale "$unit" "$src"; s=$?
    if "${SYSTEMCTL[@]}" is-active --quiet "$unit" && [ "$s" -eq 1 ]; then
      sc_log "$unit restarted onto current code"
      [ "$rc" -eq 0 ] && rc=10
    else
      sc_log "$unit still stale or down after a restart; a person should look"
      rc=11
    fi
  done
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -uo pipefail; main; exit $?; fi
