#!/usr/bin/env bash
# stale-check.sh driven through the cases that matter, with a stub systemctl
# and a stub ps. No network, no real Hermes, no real systemd. Needs Linux
# (GNU find, date, touch; flock for case 16). On Windows run it under WSL.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/templates/stale-check.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
W=""

new_world() {
  [ -n "$W" ] && rm -rf "$W"
  W="$(mktemp -d)"
  mkdir -p "$W/bin" "$W/stub" "$W/src/hermes_cli" "$W/home/profiles/work" "$W/state" "$W/log"
  export STUB_DIR="$W/stub"
  NOW="$(date +%s)"
  touch -d "@$((NOW-600))" "$W/src/hermes_cli/main.py"
  touch -d "@$((NOW-7200))" "$W/home/config.yaml" "$W/home/profiles/work/config.yaml"
  cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--user" ]; then echo user >> "$STUB_DIR/scope"; shift; fi
cmd="${1:-}"; unit="${!#}"
case "$cmd" in
  is-active) [ -f "$STUB_DIR/$unit.active" ] ;;
  show)
    if [ -f "$STUB_DIR/$unit.start" ]; then
      pid=$(( $(printf '%s' "$unit" | cksum | cut -d' ' -f1) % 30000 + 1000 ))
      printf '%s' "$unit" > "$STUB_DIR/pid-$pid"; echo "$pid"
    else echo 0; fi ;;
  stop)
    echo "stop $unit" >> "$STUB_DIR/calls"
    if [ -n "${STUB_MARKER:-}" ] && [ -f "$STUB_MARKER" ]; then cp "$STUB_MARKER" "$STUB_DIR/marker-seen"; fi
    if [ "${STUB_KILL_ON_STOP:-0}" = 1 ]; then kill -TERM "$PPID"; fi ;;
  start|restart)
    echo "$cmd $unit" >> "$STUB_DIR/calls"
    if [ "${STUB_FIXES:-1}" = 1 ]; then date +%s > "$STUB_DIR/$unit.start"; fi ;;
esac
EOF
  cat > "$W/bin/ps" <<'EOF'
#!/usr/bin/env bash
# Only the form stale-check.sh uses: ps -o etimes= -p <pid>
pid="${!#}"; unit="$(cat "$STUB_DIR/pid-$pid" 2>/dev/null)" || exit 1
echo $(( $(date +%s) - $(cat "$STUB_DIR/$unit.start") ))
EOF
  # runuser records the drop to another user, then runs the command as-is: the
  # tests run as one user, so what they can check is that the drop was asked for.
  cat > "$W/bin/runuser" <<'EOF'
#!/usr/bin/env bash
echo "runuser $*" >> "$STUB_DIR/runuser"
[ "${1:-}" = -u ] && shift 2
[ "${1:-}" = -- ] && shift
exec "$@"
EOF
  cat > "$W/bin/chown" <<'EOF'
#!/usr/bin/env bash
echo "chown $*" >> "$STUB_DIR/chown"
EOF
  cat > "$W/bin/fakepy" <<'EOF'
#!/usr/bin/env bash
echo ran >> "$STUB_DIR/fakepy-ran"
EOF
  chmod +x "$W/bin/systemctl" "$W/bin/ps" "$W/bin/runuser" "$W/bin/chown" "$W/bin/fakepy"
}
running() { touch "$STUB_DIR/$1.active"; echo $((NOW-$2)) > "$STUB_DIR/$1.start"; }
run() { # run [VAR=value ...]  prints the exit code
  env PATH="$W/bin:$PATH" HERMES_SRC="$W/src" HERMES_HOME="$W/home" HERMES_USER="$(id -un)" \
      STATE_DIR="$W/state" LOG_FILE="$W/log/stale.log" SETTLE_SECONDS=0 QUIET_RESTART=0 "$@" \
      bash "$SCRIPT" >/dev/null 2>&1; echo $?
}
calls() { cat "$STUB_DIR/calls" 2>/dev/null; }

new_world; running hermes-gateway.service 3600
rc=$(run)
[ "$rc" = 10 ] && [ "$(calls)" = "restart hermes-gateway.service" ] && ok "1 a gateway started before the newest code is restarted once (exit 10)" || bad "1 stale gateway" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 60
rc=$(run)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "2 a gateway started after the newest code is left alone" || bad "2 fresh gateway" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
touch -d "@$((NOW-7200))" "$W/src/hermes_cli/main.py"
for d in node_modules/flatted/python tests venv/lib .venv/lib __pycache__ docs website .git; do
  mkdir -p "$W/src/$d"; touch -d "@$((NOW-60))" "$W/src/$d/x.py"
done
rc=$(run)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "3 a new .py the gateway never imports (node_modules, tests, venvs, caches, docs) does not count" || bad "3 ignored folders counted" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
S="$W/opt/.venv/lib/python3.12/site-packages"; mkdir -p "$S/hermes_cli"; touch -d "@$((NOW-600))" "$S/hermes_cli/main.py"
rc=$(run HERMES_SRC="$S")
[ "$rc" = 10 ] && ok "4 a source tree that itself lives inside a .venv is still read (pruning is relative)" || bad "4 site-packages tree unread" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway-work.service 3600
touch -d "@$((NOW-7200))" "$W/src/hermes_cli/main.py"; touch -d "@$((NOW-600))" "$W/home/profiles/work/config.yaml"
rc=$(run UNITS=hermes-gateway-work.service)
[ "$rc" = 10 ] && [ "$(calls)" = "restart hermes-gateway-work.service" ] && ok "5 a profile whose config.yaml changed after start is restarted" || bad "5 config change missed" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
rc1=$(run STUB_FIXES=0); rc2=$(run STUB_FIXES=0)
[ "$rc1" = 11 ] && [ "$rc2" = 0 ] && [ "$(calls | wc -l)" = 1 ] && ok "6 a restart that does not help is reported once (exit 11) and not repeated inside the cooldown" || bad "6 cooldown" "rc1=$rc1 rc2=$rc2 calls=$(calls)"

new_world; running hermes-gateway.service 3600
touch -d "@$((NOW+86400))" "$W/src/hermes_cli/main.py"
rc=$(run)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "7 a file dated in the future never triggers a restart" || bad "7 future file" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
rc=$(run HERMES_SRC= HERMES_BIN="$W/nope")
[ "$rc" = 0 ] && [ -z "$(calls)" ] && grep -q HERMES_SRC "$W/log/stale.log" && ok "8 when the source cannot be found it restarts nothing and says to set HERMES_SRC" || bad "8 no source" "rc=$rc calls=$(calls)"

new_world; echo $((NOW-3600)) > "$STUB_DIR/hermes-gateway.service.start"
rc=$(run)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "9 a gateway that is down is left to quick-check.sh" || bad "9 down gateway touched" "rc=$rc calls=$(calls)"

new_world; touch "$STUB_DIR/hermes-gateway.service.active"
rc=$(run)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "10 no known main process means no restart (cannot tell is never a guess)" || bad "10 unknown start" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600; : > "$W/not-a-dir"
rc=$(run STATE_DIR="$W/not-a-dir")
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "11 without a writable state directory it restarts nothing" || bad "11 unwritable state" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway-work.service 3600
touch -d "@$((NOW-600))" "$W/home/profiles/work/config.yaml"
M="$W/home/profiles/work/.drain_request.json"
rc=$(run UNITS=hermes-gateway-work.service QUIET_RESTART=1 STUB_MARKER="$M")
[ "$rc" = 10 ] && [ "$(calls | tr '\n' ' ')" = "stop hermes-gateway-work.service start hermes-gateway-work.service " ] \
  && grep -q '"suppress_notification": true' "$STUB_DIR/marker-seen" && [ ! -e "$M" ] \
  && ok "12 a quiet restart writes the drain marker before stop and removes it before start" || bad "12 quiet restart" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
rc=$(run DRY_RUN=1)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && grep -q "DRY RUN" "$W/log/stale.log" && ok "13 DRY_RUN=1 logs what it would restart and restarts nothing" || bad "13 dry run" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600
rc=$(run SYSTEMCTL_USER=1)
[ "$rc" = 10 ] && grep -q user "$STUB_DIR/scope" && ok "14 SYSTEMCTL_USER=1 talks to the user scope" || bad "14 user scope" "rc=$rc"

new_world; running my-bot.service 3600
rc=$(run UNITS=my-bot.service QUIET_RESTART=1)
[ "$rc" = 10 ] && [ "$(calls)" = "restart my-bot.service" ] && ok "15 a unit outside the hermes-gateway naming gets a plain restart" || bad "15 other naming" "rc=$rc calls=$(calls)"

if command -v flock >/dev/null 2>&1; then
  new_world; running hermes-gateway.service 3600
  ( run SETTLE_SECONDS=2 >/dev/null ) & sleep 0.5; run >/dev/null; wait
  [ "$(calls | wc -l)" = 1 ] && ok "16 two sweeps at once restart a gateway once" || bad "16 overlapping sweeps" "calls=$(calls)"
else
  printf '  skip 16 flock not installed\n'
fi

new_world; running hermes-gateway.service 3600
# shellcheck disable=SC1090,SC2030
( PATH="$W/bin:$PATH"; . "$SCRIPT"; declare -F unit_is_stale >/dev/null && declare -F quiet_restart >/dev/null ) \
  && [ -z "$(calls)" ] && ok "17 sourcing the file defines its functions and restarts nothing" || bad "17 sourcing ran a sweep"

# Current Hermes installs the CLI as a /bin/sh launcher, so the interpreter cannot be read from
# its first line. `hermes --version` names the tree itself ("Install directory: <dir>").
new_world; running hermes-gateway.service 3600
printf '#!/bin/sh\necho "Hermes Agent v0.21.5 (2026.9.24)"\necho "Install directory: %s"\necho "Install method: git"\n' "$W/src" > "$W/bin/hermes"
chmod +x "$W/bin/hermes"
rc=$(run HERMES_SRC= HERMES_BIN="$W/bin/hermes")
[ "$rc" = 10 ] && [ "$(calls)" = "restart hermes-gateway.service" ] && ok "18 with HERMES_SRC unset, the tree named by hermes --version is used" || bad "18 hermes --version not used" "rc=$rc calls=$(calls) log=$(cat "$W/log/stale.log" 2>/dev/null)"

new_world; running hermes-gateway.service 3600
ln -s "$W/src" "$W/src-link"
rc=$(run HERMES_SRC="$W/src-link")
[ "$rc" = 10 ] && ok "19 a HERMES_SRC that is a symlink to the tree is still read" || bad "19 symlinked source unread" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600; : > "$W/not-a-dir"
rc=$(run LOG_FILE="$W/not-a-dir/stale.log")
[ "$rc" = 10 ] && [ "$(calls)" = "restart hermes-gateway.service" ] && ok "20 a log that cannot be written does not turn the restart into a no-op" || bad "20 unwritable log" "rc=$rc calls=$(calls)"

new_world
# shellcheck disable=SC1090,SC2317,SC2031
out="$( set -u; log() { echo caller-log; }; ts() { echo caller-ts; }
        PATH="$W/bin:$PATH"; . "$SCRIPT"
        set -o | grep -q 'pipefail.*on' && echo pipefail-on
        unit_is_stale hermes-gateway.service; echo "one-arg=$?"
        source_stamp; echo "no-arg=$?"
        log; ts )"
[ "$out" = "$(printf 'one-arg=2\nno-arg=1\ncaller-log\ncaller-ts')" ] \
  && ok "21 sourced into a set -u caller: its log and ts survive, pipefail stays off, a missing argument means cannot tell" || bad "21 sourcing side effects" "$(printf '%s' "$out" | tr '\n' ' ')"

new_world; running hermes-gateway.service 3600; echo $((NOW+2592000)) > "$W/state/hermes-gateway.service.last"
rc=$(run)
[ "$rc" = 10 ] && ok "22 a cooldown stamp dated in the future does not block the restart" || bad "22 future cooldown stamp" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway.service 3600; echo $((NOW-60)) > "$W/state/hermes-gateway.service.last"
rc=$(run STALE_COOLDOWN=1h)
[ "$rc" = 0 ] && [ -z "$(calls)" ] && ok "23 a malformed STALE_COOLDOWN falls back to one hour instead of restarting every tick" || bad "23 malformed cooldown" "rc=$rc calls=$(calls)"

new_world; running hermes-gateway-work.service 60; M="$W/home/profiles/work/.drain_request.json"
printf '{"action": "drain", "principal": "hermes-watchdog-stale-check"}\n' > "$M"
rc=$(run UNITS=hermes-gateway-work.service)
[ "$rc" = 0 ] && [ ! -e "$M" ] && ok "27 a drain marker a killed run left behind is removed at the next sweep" || bad "27 leftover marker kept" "rc=$rc"
new_world; running hermes-gateway-work.service 60; M="$W/home/profiles/work/.drain_request.json"
printf '{"action": "drain", "principal": "drain-control"}\n' > "$M"
rc=$(run UNITS=hermes-gateway-work.service)
[ -e "$M" ] && ok "27b a drain marker someone else wrote is left alone" || bad "27b someone else's marker removed"

new_world; running hermes-gateway-work.service 3600; M="$W/home/profiles/work/.drain_request.json"
touch -d "@$((NOW-600))" "$W/home/profiles/work/config.yaml"
rc=$(run UNITS=hermes-gateway-work.service QUIET_RESTART=1 STUB_KILL_ON_STOP=1)
[ ! -e "$M" ] && ok "29 a run killed during the stop does not leave its drain marker behind" || bad "29 marker left after a kill" "rc=$rc"

if [ "$(id -u)" = 0 ]; then
  new_world; running hermes-gateway-work.service 3600; M="$W/home/profiles/work/.drain_request.json"
  touch -d "@$((NOW-600))" "$W/home/profiles/work/config.yaml"
  rc=$(run UNITS=hermes-gateway-work.service QUIET_RESTART=1 HERMES_USER=svc STUB_MARKER="$M")
  [ "$rc" = 10 ] && grep -q -- '-u svc --' "$STUB_DIR/runuser" 2>/dev/null && grep -q 'drain_request.json' "$STUB_DIR/runuser" \
    && [ ! -e "$STUB_DIR/chown" ] && grep -q '"suppress_notification": true' "$STUB_DIR/marker-seen" \
    && ok "24 as root the drain marker is written as HERMES_USER, never by root, never chowned" || bad "24 marker written by root" "rc=$rc runuser=$(cat "$STUB_DIR/runuser" 2>/dev/null) chown=$(cat "$STUB_DIR/chown" 2>/dev/null)"

  new_world; running hermes-gateway-work.service 3600; M="$W/home/profiles/work/.drain_request.json"
  touch -d "@$((NOW-600))" "$W/home/profiles/work/config.yaml"
  rc=$(run UNITS=hermes-gateway-work.service QUIET_RESTART=1 HERMES_USER=svc RUNUSER="$W/nope")
  [ "$rc" = 10 ] && [ "$(calls)" = "restart hermes-gateway-work.service" ] && [ ! -e "$M" ] \
    && ok "25 as root with no way to become HERMES_USER: a plain restart and no marker" || bad "25 no runuser" "rc=$rc calls=$(calls)"

  new_world; running hermes-gateway.service 3600
  printf '#!%s\n' "$W/bin/fakepy" > "$W/bin/hermes"; chmod +x "$W/bin/hermes"
  rc=$(run HERMES_SRC= HERMES_BIN="$W/bin/hermes" HERMES_USER=svc RUNUSER="$W/nope")
  [ "$rc" = 0 ] && [ -z "$(calls)" ] && [ ! -e "$STUB_DIR/fakepy-ran" ] && grep -q HERMES_SRC "$W/log/stale.log" \
    && ok "26 as root with no way to become HERMES_USER, nothing HERMES_USER controls is executed" || bad "26 ran a user program as root" "rc=$rc ran=$(cat "$STUB_DIR/fakepy-ran" 2>/dev/null)"

  new_world; running hermes-gateway.service 3600
  printf '#!/bin/sh\necho "Install directory: %s"\n' "$W/src" > "$W/bin/hermes"; chmod +x "$W/bin/hermes"
  rc=$(run HERMES_SRC= HERMES_BIN="$W/bin/hermes" HERMES_USER=svc)
  [ "$rc" = 10 ] && grep -q -- '--version' "$STUB_DIR/runuser" 2>/dev/null \
    && ok "28 as root, hermes --version is asked as HERMES_USER" || bad "28 --version not asked as the user" "rc=$rc"
else
  printf '  skip 24-26, 28 not root: the drop to HERMES_USER cannot be exercised\n'
fi

rm -rf "$W"
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
