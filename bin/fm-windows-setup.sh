#!/usr/bin/env bash
# fm-windows-setup.sh - prepare a native Windows host (Git for Windows, no WSL)
# to run Firstmate on the Herdr backend. docs/windows.md owns the contract.
#
# Usage:
#   bin/fm-windows-setup.sh            check, then apply the missing setup
#   bin/fm-windows-setup.sh --check    report only; change nothing
#   bin/fm-windows-setup.sh --force    also replace a conflicting Herdr
#                                      terminal.default_shell
#
# What "apply" changes, each step idempotent and reported:
#   1. Herdr's config.toml gets [terminal] default_shell = Git Bash and
#      shell_mode = "login", so every Herdr pane is a bash that can run the
#      commands Firstmate types into it (Herdr's own Windows default is pwsh).
#   2. ~/.bashrc gets one marked block that puts bin/windows (the jq and
#      python3 shims) first on PATH, records the real jq.exe for the shim,
#      exports SHELL for treehouse's subshell, selects the Herdr backend, and
#      sets MSYS=winsymlinks:sys so Firstmate's symlink locks are real links.
#   3. config/backend in this Firstmate home is set to herdr when absent.
#
# Exit status: 0 ready (or applied), 1 a required tool is missing or a step
# failed, 2 not running under Git Bash on Windows.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=apply
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "fm-windows-setup.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

MARK_BEGIN='# >>> firstmate windows (bin/fm-windows-setup.sh) >>>'
MARK_END='# <<< firstmate windows <<<'
problems=0
BASHRC="${HOME:?}/.bashrc"

say() { printf '%s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
miss() { printf 'MISS  %s\n' "$*"; problems=$((problems + 1)); }

case "${OSTYPE:-}:$(uname -s 2>/dev/null)" in
  msys*|cygwin*|*:MINGW*|*:MSYS*|*:CYGWIN*) ;;
  *)
    echo "fm-windows-setup.sh: run this from Git Bash on Windows (Git for Windows); this host is $(uname -s 2>/dev/null)" >&2
    exit 2
    ;;
esac

# --- tools -------------------------------------------------------------------

tool_version() {  # <tool> <args...>
  "$@" 2>/dev/null | head -1 | tr -d '\r'
}

check_tool() {  # <name> <install-hint> [version-args...]
  local name=$1 hint=$2 version
  shift 2
  if command -v "$name" >/dev/null 2>&1; then
    version=$(tool_version "$name" "${@:---version}")
    ok "$name ${version:+($version)}"
    return 0
  fi
  miss "$name not found - $hint"
  return 1
}

say "== tools"
check_tool git "install Git for Windows: winget install Git.Git"
check_tool herdr "install Herdr 0.9.5+: powershell -ExecutionPolicy Bypass -c \"irm https://herdr.dev/install.ps1 | iex\"" --version
check_tool treehouse "install Treehouse: powershell -c \"irm https://kunchenguid.github.io/treehouse/install.ps1 | iex\"" --version
check_tool node "install Node.js LTS: winget install OpenJS.NodeJS.LTS"
check_tool gh "install GitHub CLI: winget install GitHub.cli, then gh auth login"
check_tool cygpath "cygpath ships with Git for Windows; run from Git Bash"

# The real jq: the first jq on PATH that is not Firstmate's shim.
REAL_JQ=
IFS=: read -r -a path_dirs <<<"${PATH:-}"
shim_dir=$(cd "$ROOT/bin/windows" && pwd -P)
for dir in "${path_dirs[@]}"; do
  [ -n "$dir" ] || continue
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) || continue
  [ "$resolved" != "$shim_dir" ] || continue
  for candidate in "$dir/jq.exe" "$dir/jq"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      REAL_JQ=$(cd "${candidate%/*}" && pwd -P)/${candidate##*/}
      break 2
    fi
  done
done
if [ -n "$REAL_JQ" ]; then
  jq_version=$("$REAL_JQ" --version 2>/dev/null | tr -d '\r')
  case "$jq_version" in
    jq-1.[7-9]*|jq-1.[1-9][0-9]*|jq-[2-9]*) ok "jq $jq_version at $REAL_JQ (run through the bin/windows LF shim)" ;;
    *) miss "jq $jq_version at $REAL_JQ is older than 1.7, which Firstmate needs for -b (LF output): winget install jqlang.jq" ;;
  esac
else
  miss "jq not found - winget install jqlang.jq"
fi

if PATH="$ROOT/bin/windows:$PATH" python3 -c 'import sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
  ok "python3 (through the bin/windows shim): $(PATH="$ROOT/bin/windows:$PATH" python3 --version 2>&1 | tr -d '\r')"
else
  warn "Python 3 not found - optional; Herdr push events, presentation ordering, and project groups fall back without it (winget install Python.Python.3.12)"
fi

# --- git checkout shape --------------------------------------------------------

say "== checkout"
if [ -L "$ROOT/.claude/skills" ]; then
  ok "repository symlinks are real links"
else
  warn "repository symlinks were checked out as plain files; enable Windows Developer Mode and re-clone with: git clone -c core.symlinks=true <url>"
fi
crlf=$(git -C "$ROOT" ls-files --eol 2>/dev/null | awk '$2 == "w/crlf" && $3 != "attr/-text" {print $NF}' | head -3)
if [ -z "$crlf" ]; then
  ok "working tree uses LF line endings"
else
  miss "files were checked out with CRLF ($(printf '%s' "$crlf" | tr '\n' ' ')); run: git -C \"$ROOT\" add --renormalize . && git -C \"$ROOT\" checkout -- ."
fi

# --- symlink locks -------------------------------------------------------------

say "== symlink locks"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-winsetup.XXXXXX")
mkdir -p "$probe_dir/target"
if MSYS=winsymlinks:sys ln -s "$probe_dir/target" "$probe_dir/link" 2>/dev/null \
  && [ -L "$probe_dir/link" ] && [ "$(readlink "$probe_dir/link")" = "$probe_dir/target" ]; then
  ok "MSYS=winsymlinks:sys gives real symlinks for Firstmate's locks"
else
  miss "ln -s did not create a readable symlink even with MSYS=winsymlinks:sys"
fi
rm -rf "$probe_dir"

# --- Herdr pane shell --------------------------------------------------------

say "== herdr pane shell"
git_root_win=$(cygpath -w / 2>/dev/null | tr -d '\r')
git_root_win=${git_root_win%\\}
# The pane shell is Git's usr\bin\bash.exe itself, not the bin\bash.exe
# launcher: the launcher starts the real bash one process down, which hides
# that bash's pid, children, and cwd from Herdr and from the idle-shell proof
# (measured on windows-latest with Herdr 0.9.5; docs/windows.md).
BASH_WIN="$git_root_win\\usr\\bin\\bash.exe"
BASH_WRAPPER_WIN="$git_root_win\\bin\\bash.exe"
if [ ! -f "$(cygpath -u "$BASH_WIN" 2>/dev/null)" ]; then
  miss "could not locate Git Bash's usr\\bin\\bash.exe under $git_root_win"
  BASH_WIN=
fi

if [ -n "${HERDR_CONFIG_PATH:-}" ]; then
  HERDR_CONFIG=$(cygpath -u "$HERDR_CONFIG_PATH" 2>/dev/null || printf '%s' "$HERDR_CONFIG_PATH")
elif [ -n "${APPDATA:-}" ]; then
  HERDR_CONFIG="$(cygpath -u "$APPDATA" 2>/dev/null || printf '%s' "$APPDATA")/herdr/config.toml"
else
  HERDR_CONFIG=
  miss "neither HERDR_CONFIG_PATH nor APPDATA is set; cannot find Herdr's config.toml"
fi

# toml_terminal_value <file> <key>: the raw value of <key> inside [terminal].
toml_terminal_value() {
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    /^[[:space:]]*\[/ { in_terminal = ($0 ~ /^[[:space:]]*\[terminal\][[:space:]]*(#.*)?$/) ; next }
    in_terminal && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", ""); sub(/[[:space:]]*(#.*)?$/, ""); print; exit
    }
  ' "$1" | tr -d '\r'
}

# toml_terminal_set <file> <key> <toml-value>: set <key> in [terminal],
# replacing an existing assignment, adding it under an existing header, or
# appending a new [terminal] table.
toml_terminal_set() {
  local file=$1 key=$2 value=$3 tmp
  mkdir -p "$(dirname "$file")" || return 1
  [ -f "$file" ] || : >"$file" || return 1
  tmp="$file.fm-tmp.$$"
  # The value travels through ENVIRON, not -v: awk -v would interpret the
  # backslashes of a Windows path as escape sequences.
  FM_TOML_KEY=$key FM_TOML_VALUE=$value awk '
    BEGIN { key = ENVIRON["FM_TOML_KEY"]; value = ENVIRON["FM_TOML_VALUE"] }
    function emit() { print key " = " value; done = 1 }
    /^[[:space:]]*\[/ {
      if (in_terminal && !done) emit()
      in_terminal = ($0 ~ /^[[:space:]]*\[terminal\][[:space:]]*(#.*)?$/)
      if (in_terminal) seen = 1
      print; next
    }
    in_terminal && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!done) emit(); next }
    { print }
    END {
      if (in_terminal && !done) emit()
      else if (!seen) { print ""; print "[terminal]"; emit() }
    }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

toml_string() {  # <text>: a TOML literal string (no escapes; Windows paths contain no single quote)
  printf "'%s'" "$1"
}

if [ -n "$HERDR_CONFIG" ] && [ -n "$BASH_WIN" ]; then
  current_shell=$(toml_terminal_value "$HERDR_CONFIG" default_shell)
  current_mode=$(toml_terminal_value "$HERDR_CONFIG" shell_mode)
  case "$current_shell" in
    "'$BASH_WIN'"|"\"$BASH_WIN\"")
      ok "herdr terminal.default_shell is Git Bash: $current_shell"
      ;;
    ''|"''"|'""'|"'$BASH_WRAPPER_WIN'"|"\"$BASH_WRAPPER_WIN\"")
      if [ "$MODE" = apply ]; then
        if toml_terminal_set "$HERDR_CONFIG" default_shell "$(toml_string "$BASH_WIN")"; then
          ok "set herdr terminal.default_shell = $BASH_WIN in $HERDR_CONFIG"
        else
          miss "could not write $HERDR_CONFIG"
        fi
      else
        miss "herdr terminal.default_shell is ${current_shell:-unset}, not $BASH_WIN; run bin/fm-windows-setup.sh to set it"
      fi
      ;;
    *)
      if [ "$MODE" = apply ] && [ "$FORCE" = 1 ]; then
        if toml_terminal_set "$HERDR_CONFIG" default_shell "$(toml_string "$BASH_WIN")"; then
          ok "replaced herdr terminal.default_shell $current_shell with $BASH_WIN"
        else
          miss "could not write $HERDR_CONFIG"
        fi
      else
        miss "herdr terminal.default_shell is $current_shell, not Git Bash; Firstmate types bash commands into panes. Re-run with --force to replace it"
      fi
      ;;
  esac
  case "$current_mode" in
    *login*) ok "herdr terminal.shell_mode is $current_mode" ;;
    *)
      if [ "$MODE" = apply ]; then
        if toml_terminal_set "$HERDR_CONFIG" shell_mode '"login"'; then
          ok "set herdr terminal.shell_mode = \"login\" so panes read $BASHRC through Git Bash's profile"
        else
          miss "could not write $HERDR_CONFIG"
        fi
      else
        warn "herdr terminal.shell_mode is ${current_mode:-auto}; \"login\" makes every pane load the Firstmate PATH block"
      fi
      ;;
  esac
  if [ "$MODE" = apply ] && command -v herdr >/dev/null 2>&1; then
    herdr server reload-config >/dev/null 2>&1 && ok "asked a running herdr server to reload its config" || true
  fi
fi

# --- ~/.bashrc block ---------------------------------------------------------

say "== shell environment"
block() {
  printf '%s\n' "$MARK_BEGIN"
  printf '%s\n' '# Managed by Firstmate; re-run bin/fm-windows-setup.sh to refresh.'
  # The block is written for a later shell to expand, so these single quotes
  # are deliberate.
  # shellcheck disable=SC2016
  printf 'export PATH="%s:$PATH"\n' "$ROOT/bin/windows"
  [ -z "$REAL_JQ" ] || printf 'export FM_WINDOWS_JQ="%s"\n' "$REAL_JQ"
  printf '%s\n' 'export SHELL=/usr/bin/bash'
  # shellcheck disable=SC2016
  printf '%s\n' 'export MSYS="${MSYS:+$MSYS }winsymlinks:sys"'
  # shellcheck disable=SC2016
  printf '%s\n' 'export FM_BACKEND="${FM_BACKEND:-herdr}"'
  printf '%s\n' "$MARK_END"
}
want=$(block)
have=
if [ -f "$BASHRC" ]; then
  have=$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {p = 1} p {print} $0 == e {p = 0}' "$BASHRC" | tr -d '\r')
fi
if [ "$have" = "$want" ]; then
  ok "$BASHRC already carries the Firstmate block"
elif [ "$MODE" = apply ]; then
  tmp="$BASHRC.fm-tmp.$$"
  if { if [ -f "$BASHRC" ]; then
         awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$BASHRC"
       fi
       printf '%s\n' "$want"; } >"$tmp" && mv "$tmp" "$BASHRC"; then
    ok "wrote the Firstmate block to $BASHRC (open a new Git Bash window to load it)"
  else
    miss "could not update $BASHRC"
  fi
else
  miss "$BASHRC lacks the current Firstmate block; run bin/fm-windows-setup.sh"
fi
if [ ! -f "${HOME}/.bash_profile" ] && [ "$MODE" = apply ]; then
  printf '%s\n' '# Login shells (Git Bash, Herdr panes) also read ~/.bashrc.' '[ -f ~/.bashrc ] && . ~/.bashrc' >"${HOME}/.bash_profile" \
    && ok "created ~/.bash_profile that sources ~/.bashrc"
fi

# --- backend selection ---------------------------------------------------------

say "== firstmate backend"
backend_file="$ROOT/config/backend"
if [ -f "$backend_file" ]; then
  ok "config/backend is $(tr -d '\r\n' <"$backend_file")"
elif [ "$MODE" = apply ]; then
  mkdir -p "$ROOT/config" && printf 'herdr\n' >"$backend_file" && ok "set config/backend to herdr"
else
  warn "config/backend is absent; FM_BACKEND from the ~/.bashrc block selects herdr"
fi

say ""
if [ "$problems" -eq 0 ]; then
  say "Windows setup: ready. Start Herdr in Windows Terminal (herdr), then start your agent in a Herdr pane inside this repository."
  exit 0
fi
say "Windows setup: $problems item(s) need attention (see MISS lines above)."
exit 1
