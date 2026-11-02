#!/usr/bin/env bash
# bin/fm-windows-hc-probe.sh - end-to-end probe of the native Windows
# herdr-core path (backend hc, the core under the Herdr app; docs/windows.md),
# run by .github/workflows/windows-herdr.yml on a windows-latest runner under
# Git Bash with herdr-core, jq.exe, and treehouse installed and
# `bin/fm-windows-setup.sh --backend hc` applied.
#
# Each check prints one "PASS|FAIL|INFO <name>: <detail>" line and the probe
# exits 1 if any check failed. It drives the adapter's own functions against
# ONE private, never-default hc session, and stops only that session's core on
# exit.

# The small predicates below are called through wait_for, and the ps listing
# is a diagnostic only.
# shellcheck disable=SC2329,SC2009
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="fm-win-hc-${GITHUB_RUN_ID:-local}-$$"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-win-hc.XXXXXX")
failures=0

pass() { printf 'PASS %s: %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
info() { printf 'INFO %s: %s\n' "$1" "$2"; }
oneline() { tr '\r\n' '  ' | cut -c1-"${1:-600}"; }

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$SCRATCH/home"
export HC_SESSION="$SESSION"
mkdir -p "$FM_HOME/state"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || { echo "FAIL source: fm_backend_source hc failed"; exit 1; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -z "${TARGET:-}" ] || fm_backend_kill hc "$TARGET" >/dev/null 2>&1 || true
  fm_backend_hc_cli "$SESSION" server stop >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# wait_for <seconds> <command...>: poll until the command succeeds.
wait_for() {
  local limit=$1 i
  shift
  for i in $(seq 1 $((limit * 5))); do
    "$@" && return 0
    [ "$i" -gt 0 ] && sleep 0.2
  done
  return 1
}

# --- platform and tools -------------------------------------------------------

if fm_backend_hc_windows_host; then
  pass platform "Windows host detected ($(uname -s))"
else
  fail platform "fm_backend_hc_windows_host did not detect $(uname -s)"
fi
info herdr-core "$(fm_backend_hc_bin) -> $("$(fm_backend_hc_bin)" --version 2>&1 | oneline)"
info herdr-app "$(command -v herdr-app 2>/dev/null || echo 'not installed') $(herdr-app --version 2>/dev/null | oneline)"
info hc-config "$(cat "$(cygpath -u "$APPDATA")/herdr-core/config.toml" 2>&1 | oneline)"

if fm_backend_hc_version_check 2>"$SCRATCH/version.err"; then
  pass version "herdr-core is at or above the adapter's floor $FM_BACKEND_HC_MIN_VERSION"
else
  fail version "$(oneline <"$SCRATCH/version.err")"
fi
if got=$(fm_backend_hc_container_ensure 2>"$SCRATCH/ensure.err") && [ "$got" = "$SESSION" ]; then
  pass core "private session $SESSION started and answered the generation-1 hello over hc connect"
else
  fail core "container_ensure failed: $(oneline <"$SCRATCH/ensure.err")"
  info core-start "$(fm_backend_hc_cli "$SESSION" server start --json 2>&1 | oneline 800)"
  info core-status "$(fm_backend_hc_cli "$SESSION" server status --json 2>&1 | oneline 800)"
  info hello-piped "$(printf '%s\n' '{"jsonrpc":"2.0","method":"hello","params":{"generation":1},"id":1}' \
    | fm_backend_hc_env_run "$SESSION" connect --session "$SESSION" 2>&1 | oneline 800) rc=${PIPESTATUS[1]}"
  info hello-held "$(fm_backend_hc_hello_held "$SESSION" '{"jsonrpc":"2.0","method":"hello","params":{"generation":1},"id":1}' 2>&1 | oneline 800)"
  exit 1
fi

# --- task terminal ------------------------------------------------------------

project="$SCRATCH/project dir"
mkdir -p "$project/cwd probe"
git init -q "$project" && git -C "$project" -c user.email=p@example.com -c user.name=probe commit -q --allow-empty -m init
# The adapter's own canonical spelling of the folder (/tmp is a mount of the
# user's Temp folder, which can also read as /c/Users/... or an 8.3 name).
project_real=$(fm_windows_canonical_path "$project")
label=fm-probe1
if address=$(fm_backend_hc_create_task "$SESSION" "$label" "$project_real" 2>"$SCRATCH/create.err"); then
  TARGET="$SESSION:$address"
  pass create "task terminal $address created with Firstmate's labels"
else
  fail create "$(oneline <"$SCRATCH/create.err")"
  exit 1
fi

# The shell needs a moment before hc reports a foreground process.
shell_up() { [ -n "$(fm_backend_hc_get "$TARGET" | jq -r '.foreground.pid // empty')" ]; }
wait_for 15 shell_up || true
json=$(fm_backend_hc_get "$TARGET")
info get "$(printf '%s' "$json" | oneline 1200)"
fg_name=$(printf '%s' "$json" | jq -r '.foreground.name // empty')
fg_argv0=$(printf '%s' "$json" | jq -r '.foreground.argv[0] // empty')
if [ "$(fm_agent_process_classify "$fg_name" "$fg_argv0" "$fg_argv0")" = shell ]; then
  pass shell "the terminal runs Git Bash ($fg_name, $fg_argv0)"
else
  fail shell "the terminal's foreground '$fg_name' ($fg_argv0) is not a shell; is herdr-core's shell set?"
fi
labels=$(printf '%s' "$json" | jq -c '.labels // {}')
case "$labels" in
  *'"herdr.space"'*'"herdr.tab"'*|*'"herdr.tab"'*'"herdr.space"'*) pass labels "Herdr app space and tab labels are set: $labels" ;;
  *) fail labels "the terminal lacks herdr.space/herdr.tab: $labels" ;;
esac
if [ "$(fm_backend_hc_endpoint_state "$TARGET" "$label")" = ready ]; then
  pass identity "the terminal answers as this home's $label"
else
  fail identity "endpoint_state is $(fm_backend_hc_endpoint_state "$TARGET" "$label")"
fi

# --- typed input and screen ------------------------------------------------------

marker="FM_HC_PROBE_$$"
fm_backend_hc_send_text_line "$TARGET" "echo ${marker}_\$BASH_VERSION" "$label" || true
screen_has_marker() { fm_backend_hc_capture "$TARGET" 50 "$label" | grep -q "${marker}_[0-9]"; }
if wait_for 10 screen_has_marker; then
  pass send "bash ran a typed command: $(fm_backend_hc_capture "$TARGET" 50 "$label" | grep "${marker}_[0-9]" | tail -1 | oneline 120)"
else
  fail send "the typed command never printed: $(fm_backend_hc_capture "$TARGET" 20 "$label" | oneline)"
fi

# --- current path ------------------------------------------------------------------

path_is() { [ "$(fm_backend_hc_current_path "$TARGET" "$label")" = "$1" ]; }
if wait_for 5 path_is "$project_real"; then
  pass cwd-start "current path is the project folder: $project_real"
else
  fail cwd-start "current path '$(fm_backend_hc_current_path "$TARGET" "$label")' is not '$project_real'"
fi
fm_backend_hc_send_text_line "$TARGET" "cd 'cwd probe'" "$label" || true
if wait_for 5 path_is "$project_real/cwd probe"; then
  pass cwd-follow "current path follows cd: $project_real/cwd probe"
else
  fail cwd-follow "current path '$(fm_backend_hc_current_path "$TARGET" "$label")' did not follow cd; hc reports $(fm_backend_hc_get "$TARGET" | jq -r '.foreground.cwd')"
fi
fm_backend_hc_send_text_line "$TARGET" "bash" "$label" || true
fm_backend_hc_send_text_line "$TARGET" "cd .." "$label" || true
if wait_for 5 path_is "$project_real"; then
  pass cwd-subshell "current path follows a subshell's cd, as after treehouse get"
else
  fail cwd-subshell "current path '$(fm_backend_hc_current_path "$TARGET" "$label")' did not follow the subshell"
fi
fm_backend_hc_send_text_line "$TARGET" "exit" "$label" || true

# --- agent state --------------------------------------------------------------------

state_is() { [ "$(fm_backend_agent_state hc "$TARGET")" = "$1" ]; }
if wait_for 5 state_is dead; then
  pass state-idle "an idle shell reads dead (no agent)"
else
  fail state-idle "an idle shell reads $(fm_backend_agent_state hc "$TARGET")"
fi
fm_backend_hc_send_text_line "$TARGET" "sleep 20" "$label" || true
if wait_for 5 state_is ambiguous; then
  pass state-other "a shell running sleep reads ambiguous, never dead"
else
  fail state-other "a shell running sleep reads $(fm_backend_agent_state hc "$TARGET")"
fi
fm_backend_hc_send_key "$TARGET" C-c "$label" || true
# A stand-in harness: an MSYS binary named claude.exe, which Git Bash's process
# table lists by its own path.
mkdir -p "$SCRATCH/bin"
cp /usr/bin/sleep.exe "$SCRATCH/bin/claude.exe"
wait_for 5 state_is dead || true
fm_backend_hc_send_text_line "$TARGET" "'$SCRATCH/bin/claude.exe' 30" "$label" || true
if wait_for 5 state_is alive; then
  pass state-agent "a shell running claude.exe reads alive"
else
  fail state-agent "a shell running claude.exe reads $(fm_backend_agent_state hc "$TARGET"); ps: $(ps -W | grep -i -e claude -e bash | oneline 800)"
fi
info busy "native busy state: $(fm_backend_busy_state hc "$TARGET" 2>/dev/null)"
fm_backend_hc_send_key "$TARGET" C-c "$label" || true
wait_for 5 state_is dead || true

# --- submit -------------------------------------------------------------------------

verdict=$(fm_backend_hc_send_text_submit "$TARGET" "echo submitted_$$" 3 0.4 0.5 "$label" 2>"$SCRATCH/submit.err")
info submit "send_text_submit verdict: $verdict $(oneline <"$SCRATCH/submit.err")"
submitted() { fm_backend_hc_capture "$TARGET" 50 "$label" | grep -q "^submitted_$$"; }
if wait_for 5 submitted; then
  pass submit "a submitted line ran"
else
  fail submit "the submitted line never ran: $(fm_backend_hc_capture "$TARGET" 20 "$label" | oneline)"
fi

# --- treehouse worktree --------------------------------------------------------------

if wt=$(cd "$project_real" && treehouse get --lease --lease-holder fm-win-hc-probe 2>"$SCRATCH/treehouse.err"); then
  wt=$(printf '%s' "$wt" | tr -d '\r' | tail -1)
  if top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null); then
    pass treehouse "leased worktree $wt (git toplevel $top)"
  else
    fail treehouse "treehouse returned '$wt', which git cannot read"
  fi
  (cd "$project_real" && treehouse return --force "$wt") >/dev/null 2>&1 || true
else
  fail treehouse "treehouse get --lease failed: $(oneline <"$SCRATCH/treehouse.err")"
fi

# --- close ---------------------------------------------------------------------------

if fm_backend_kill hc "$TARGET" "" "$label" 2>"$SCRATCH/kill.err"; then
  if [ "$(fm_backend_hc_endpoint_state "$TARGET")" = absent ]; then
    pass close "the task terminal was ended and removed"
    TARGET=
  else
    fail close "the terminal is still $(fm_backend_hc_endpoint_state "$TARGET") after close"
  fi
else
  fail close "$(oneline <"$SCRATCH/kill.err")"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "windows herdr-core probe: all checks passed"
  exit 0
fi
echo "windows herdr-core probe: $failures check(s) failed"
exit 1
