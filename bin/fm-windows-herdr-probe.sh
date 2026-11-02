#!/usr/bin/env bash
# bin/fm-windows-herdr-probe.sh - end-to-end probe of the native
# Windows Herdr path (docs/windows.md), run by .github/workflows/windows-herdr.yml
# on a windows-latest runner under Git Bash with herdr.exe, jq.exe, treehouse,
# and Python installed and bin/fm-windows-setup.sh applied.
#
# Each check prints one "PASS|FAIL|INFO <name>: <detail>" line and the probe
# exits 1 if any check failed. It uses ONE private, never-default Herdr
# session and stops and deletes only that session on exit.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="fm-win-probe-${GITHUB_RUN_ID:-local}-$$"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-win-probe.XXXXXX")
SERVER_PID=
failures=0

pass() { printf 'PASS %s: %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
info() { printf 'INFO %s: %s\n' "$1" "$2"; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  if command -v herdr >/dev/null 2>&1; then
    herdr session stop "$SESSION" --session "$SESSION" >/dev/null 2>&1 || true
    herdr session delete "$SESSION" --session "$SESSION" >/dev/null 2>&1 || true
  fi
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$SCRATCH/home"
mkdir -p "$FM_HOME/state"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "FAIL source: fm_backend_source herdr failed"; exit 1; }

h() { fm_backend_herdr_cli "$SESSION" "$@"; }

# --- platform and tools -------------------------------------------------------

if fm_backend_herdr_windows_host; then
  pass platform "Windows host detected ($(uname -s))"
else
  fail platform "fm_backend_herdr_windows_host did not detect $(uname -s)"
fi
info herdr "$(herdr --version 2>&1 | head -1)"
info jq "$(command -v jq) -> $(jq --version 2>&1)"
info python3 "$(command -v python3) -> $(python3 --version 2>&1)"
info treehouse "$(treehouse --version 2>&1 | head -1)"

if [ "$(printf '{"a":"x"}' | jq -r .a | od -An -c | tr -d ' \n')" = 'x\n' ]; then
  pass jq-lf "jq output is LF-only through the bin/windows shim"
else
  fail jq-lf "jq output still carries CR: $(printf '{"a":"x"}' | jq -r .a | od -An -c)"
fi
if [ "$(python3 -c 'print("x")' | od -An -c | tr -d ' \n')" = 'x\r\n' ]; then
  info python-crlf "plain Python print writes CRLF on Windows; the Herdr helpers force LF themselves"
fi

# --- server and pane ----------------------------------------------------------

herdr server --session "$SESSION" >"$SCRATCH/server.log" 2>&1 &
SERVER_PID=$!
ready=0
for _ in $(seq 1 100); do
  if [ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ]; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" = 1 ]; then
  pass server "named session $SESSION is running"
else
  fail server "server did not start: $(tail -n 3 "$SCRATCH/server.log" | tr '\n' ' ')"
  exit 1
fi

out=$(h workspace create --cwd "$ROOT" --label fm-win-probe --no-focus 2>&1)
PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
if [ -n "$PANE" ]; then
  pass workspace "root pane $PANE"
else
  fail workspace "workspace create failed: $out"
  exit 1
fi

info process-info "$(h pane process-info --pane "$PANE" 2>&1 | tr -d '\n' | cut -c1-600)"
shell_name=$(h pane process-info --pane "$PANE" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].name // empty')
case "$shell_name" in
  bash|bash.exe|*/bash|*/bash.exe|*\\bash.exe) pass pane-shell "Herdr panes start Git Bash ($shell_name)" ;;
  *) fail pane-shell "Herdr pane shell is '$shell_name', not bash; terminal.default_shell was not applied" ;;
esac

marker="FM_WIN_PROBE_$$"
if h pane run "$PANE" "echo ${marker}_\$BASH_VERSION" >/dev/null 2>&1 \
  && h pane wait-output "$PANE" --match "${marker}_" --timeout 15000 >/dev/null 2>&1; then
  pass pane-run "bash executed a typed command: $(h pane read "$PANE" --source recent --lines 20 2>/dev/null | grep -m1 "${marker}_" | tr -d '\r')"
else
  fail pane-run "typed command did not echo in the pane"
fi

# --- idle-shell proof (Windows process-info form) -------------------------------

sleep 1
if pid=$(fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$PANE"); then
  pass idle-proof "idle Git Bash pane proved idle (shell pid $pid)"
else
  fail idle-proof "idle Git Bash pane was not proved idle"
fi
h pane run "$PANE" "sleep 20" >/dev/null 2>&1
sleep 2
info process-info-busy "$(h pane process-info --pane "$PANE" 2>&1 | tr -d '\n' | cut -c1-900)"
info pane-get-busy "$(h pane get "$PANE" 2>&1 | tr -d '\n' | cut -c1-900)"
info agent-get-busy "$(h agent get "$PANE" 2>&1 | tr -d '\n' | cut -c1-400)"
# shellcheck disable=SC2009  # Git Bash has no pgrep -W equivalent
info ps-busy "$(ps -W 2>/dev/null | grep -iE 'bash|sleep' | tr -s ' ' | tr '\n' ';' | cut -c1-900)"
if FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$PANE" >/dev/null; then
  fail busy-proof "a pane running 'sleep 20' was wrongly proved idle"
else
  pass busy-proof "a pane running 'sleep 20' is refused by the idle proof"
fi
h pane send-keys "$PANE" ctrl+c >/dev/null 2>&1
sleep 1

# --- current path -----------------------------------------------------------------

mkdir -p "$SCRATCH/cwd probe"
h pane run "$PANE" "cd '$SCRATCH/cwd probe'" >/dev/null 2>&1
sleep 1.5
info pane-get-cd "$(h pane get "$PANE" 2>&1 | tr -d '\n' | cut -c1-900)"
info process-info-cd "$(h pane process-info --pane "$PANE" 2>&1 | tr -d '\n' | cut -c1-900)"
cwd=$(fm_backend_herdr_current_path "$SESSION:$PANE")
want=$(cd "$SCRATCH/cwd probe" && pwd -P)
got=$(cd "$cwd" 2>/dev/null && pwd -P)
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  pass current-path "foreground cwd $cwd resolves to $want"
else
  fail current-path "foreground cwd '$cwd' does not resolve to '$want'"
fi

# --- control socket and push events ---------------------------------------------------

sock=$(fm_backend_herdr_socket_path "$SESSION")
info socket "session list socket_path: ${sock:-<empty>}"
if canon=$(fm_backend_herdr_canonical_socket_path "$sock"); then
  pass socket-path "canonical form: $canon"
else
  fail socket-path "canonical socket path refused '$sock'"
fi
if [ -n "$sock" ]; then
  rc=0
  diag=$(python3 "$ROOT/bin/backends/herdr-eventwait.py" "$sock" 2 "$PANE" 2>&1) || rc=$?
  info eventwait-direct "rc=$rc output=$(printf '%s' "$diag" | tr '\n' ' ' | cut -c1-400)"
  diag=$(cd "$ROOT/bin/backends" && python3 -c '
import sys, traceback, json, herdr_transport
try:
    s = herdr_transport.connect(sys.argv[1], 5)
    s.sendall((json.dumps({"id": "d", "method": "session.snapshot", "params": {}}) + "\n").encode())
    s.settimeout(5)
    print("connected; first bytes:", s.recv(200)[:200])
except Exception:
    traceback.print_exc()
' "$sock" 2>&1)
  info transport-direct "$(printf '%s' "$diag" | tr '\n' ' ' | cut -c1-900)"
fi
if fm_backend_herdr_events_capable "$SESSION"; then
  pass events-capable "events.subscribe capability gate passes"
  rc=0
  fm_backend_herdr_wait_transition "$SESSION" 3 "$FM_HOME/state" "$SESSION:$PANE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 1 ]; then
    pass event-timeout "subscriber held the stream for the full 3s budget (rc 1)"
  else
    fail event-timeout "bounded wait returned $rc, expected the clean-timeout 1"
  fi
  (
    sleep 2
    fm_backend_herdr_cli "$SESSION" pane report-agent "$PANE" --source fm-win-probe \
      --agent claude --state blocked >/dev/null 2>&1
  ) &
  reporter=$!
  rc=0
  record=$(fm_backend_herdr_wait_transition "$SESSION" 15 "$FM_HOME/state" "$SESSION:$PANE" 2>&1) || rc=$?
  wait "$reporter" 2>/dev/null || true
  if [ "$rc" = 0 ]; then
    pass event-blocked "a reported blocked edge arrived over the Windows control socket: $(printf '%s' "$record" | tr '\n' ' ')"
  else
    fail event-blocked "blocked edge wait returned $rc: $record"
  fi
  h pane release-agent "$PANE" --source fm-win-probe --agent claude >/dev/null 2>&1 || true
else
  fail events-capable "events capability gate failed (python3 or protocol)"
fi

# --- treehouse worktree --------------------------------------------------------------

repo="$SCRATCH/repo"
git init -q "$repo" && git -C "$repo" -c user.email=p@example.com -c user.name=probe commit -q --allow-empty -m init
if wt=$(cd "$repo" && treehouse get --lease --lease-holder fm-win-probe 2>"$SCRATCH/treehouse.err"); then
  wt=$(printf '%s' "$wt" | tr -d '\r' | tail -1)
  if top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null); then
    pass treehouse "leased worktree $wt (git toplevel $top)"
  else
    fail treehouse "treehouse returned '$wt', which git cannot read"
  fi
  (cd "$repo" && treehouse return --force "$wt") >/dev/null 2>&1 || true
else
  fail treehouse "treehouse get --lease failed: $(tr '\n' ' ' <"$SCRATCH/treehouse.err")"
fi

# --- pane-death close --------------------------------------------------------------

out=$(h pane split "$PANE" --direction right --no-focus 2>&1)
SPLIT=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty')
sleep 1.5
if [ -n "$SPLIT" ] && pid=$(fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$SPLIT"); then
  if fm_backend_herdr_death_close_pane "$SESSION" "$SPLIT" "$pid"; then
    pass death-close "idle split pane $SPLIT closed through its own shell exit"
  else
    fail death-close "death close did not remove split pane $SPLIT"
  fi
else
  fail death-close "could not create and prove an idle split pane: $out"
fi

# --- diagnostics: Git's usr\bin\bash.exe without the bin\bash.exe wrapper ---

config_file="$(cygpath -u "$APPDATA")/herdr/config.toml"
if [ -f "$config_file" ]; then
  cp "$config_file" "$SCRATCH/config.toml.bak"
  printf "[terminal]\ndefault_shell = '%s'\nshell_mode = \"login\"\n" "$(cygpath -w /usr/bin/bash.exe)" >"$config_file"
  info alt-config "$(tr '\n' '|' <"$config_file")"
  h server reload-config >/dev/null 2>&1 || true
  out=$(h tab create --cwd "$ROOT" --label fm-win-usrbash --no-focus 2>&1)
  ALT=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  if [ -n "$ALT" ]; then
    sleep 2
    info alt-idle "$(h pane process-info --pane "$ALT" 2>&1 | tr -d '\n' | cut -c1-900)"
    h pane run "$ALT" "sleep 20" >/dev/null 2>&1
    sleep 2
    info alt-busy "$(h pane process-info --pane "$ALT" 2>&1 | tr -d '\n' | cut -c1-900)"
    # shellcheck disable=SC2009  # Git Bash has no pgrep -W equivalent
    info alt-ps-busy "$(ps -W 2>/dev/null | grep -iE 'bash|sleep' | tr -s ' ' | tr '\n' ';' | cut -c1-900)"
    h pane send-keys "$ALT" ctrl+c >/dev/null 2>&1
    sleep 1
    mkdir -p "$SCRATCH/alt cwd"
    h pane run "$ALT" "cd '$SCRATCH/alt cwd'" >/dev/null 2>&1
    sleep 1.5
    info alt-cd "$(h pane get "$ALT" 2>&1 | tr -d '\n' | cut -c1-900)"
    info alt-cd-process "$(h pane process-info --pane "$ALT" 2>&1 | tr -d '\n' | cut -c1-900)"
    # shellcheck disable=SC2016  # expands inside the pane's shell
    h pane run "$ALT" 'echo "ALTENV MSYSTEM=$MSYSTEM git=$(command -v git) jq=$(command -v jq)"' >/dev/null 2>&1
    sleep 1
    info alt-read "$(h pane read "$ALT" --source recent --lines 15 2>&1 | tr '\n' '|' | cut -c1-600)"
  else
    info alt-shell "tab create failed: $out"
  fi
  cp "$SCRATCH/config.toml.bak" "$config_file"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "windows herdr probe: all checks passed"
  exit 0
fi
echo "windows herdr probe: $failures check(s) failed"
exit 1
