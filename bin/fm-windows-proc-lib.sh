#!/usr/bin/env bash
# bin/fm-windows-proc-lib.sh - native Windows (Git for Windows / MSYS) process
# facts shared by the backends that drive a native Windows terminal host:
# Herdr 1 (bin/backends/herdr.sh) and herdr-core (bin/backends/hc.sh).
# docs/windows.md owns the operator contract.
#
# Both hosts report a terminal's process as a Windows pid with no Unix
# foreground process group: on a pseudo console the reported process is the
# terminal's first program, the pane shell, even while it runs a command
# (measured on windows-latest with herdr 0.9.5; herdr-core documents the same
# in its foreground.rs). Git Bash's `ps -W` maps that Windows pid onto the MSYS
# process table, where children, consoles, and /proc/<pid>/cwd are readable.
#
# FM_WINDOWS_PS_BIN replaces `ps` and FM_PROC_ROOT_OVERRIDE replaces /proc for
# tests. Sourced; defines functions only.

# fm_windows_host: true under Git Bash, MSYS, or Cygwin on Windows.
# FM_WINDOWS_HOST (1 or 0) overrides detection for tests.
fm_windows_host() {
  case "${FM_WINDOWS_HOST:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*) return 0 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# fm_windows_posix_path: <path> in Git Bash form (C:\work\repo becomes
# /c/work/repo); unchanged for anything that is not a drive path or that
# cygpath cannot convert.
fm_windows_posix_path() {  # <path>
  local path=$1 converted
  case "$path" in
    [A-Za-z]:[\\/]*|[A-Za-z]:)
      if command -v cygpath >/dev/null 2>&1 && converted=$(cygpath -u -- "$path" 2>/dev/null) && [ -n "$converted" ]; then
        printf '%s' "${converted%/}"
        return 0
      fi
      ;;
  esac
  printf '%s' "$path"
}

# fm_windows_ps_rows: Git Bash's process table as
# "<pid> <ppid> <winpid> <tty> <msys> <command>" lines. Cygwin's `ps -W`
# prints PID PPID PGID WINPID TTY UID STIME COMMAND, with an optional leading
# status letter (I, S, O) that is dropped here. <msys> is 1 for an MSYS
# process and 0 for a Windows-only row, which `ps -W` lists with PPID and PGID
# 0 and a synthetic PID (Git's bin\bash.exe wrapper is one). A native program
# that an MSYS process started is an MSYS row whose command is its .exe path.
fm_windows_ps_rows() {
  local ps_bin=${FM_WINDOWS_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  "$ps_bin" -W 2>/dev/null | awk '
    NR == 1 { next }
    {
      if ($1 !~ /^[0-9]+$/) { $1 = ""; $0 = $0 }
      if (NF < 8) next
      command = $8
      for (i = 9; i <= NF; i++) command = command " " $i
      print $1, $2, $4, $5, ($3 == 0 ? 0 : 1), command
    }'
}

# fm_windows_shell_quiet: true when the MSYS shell whose Windows pid is
# <winpid> runs nothing. The shell is busy when any MSYS process names it as
# parent, or when any other process holds its console: a native program such
# as treehouse.exe breaks the MSYS parent chain, but the bash it starts still
# shares the terminal's console. A shell absent from the table (Git's
# bin\bash.exe wrapper, which hides the real bash one level down) is never
# proved quiet.
fm_windows_shell_quiet() {  # <winpid>
  local winpid=$1 rows
  rows=$(fm_windows_ps_rows) || return 1
  printf '%s\n' "$rows" | awk -v winpid="$winpid" '
    { pid[NR] = $1; ppid[NR] = $2; tty[NR] = $4 }
    $3 == winpid && $5 == 1 { shell = $1; console = $4; found++ }
    END {
      if (found != 1) exit 1
      for (i = 1; i <= NR; i++) {
        if (pid[i] == shell) continue
        if (ppid[i] == shell) exit 1
        if (console != "?" && tty[i] == console) exit 1
      }
      exit 0
    }'
}

# fm_windows_console_cwd: the cwd, in Git Bash form, of the newest bash on the
# console of the MSYS shell whose Windows pid is <winpid>. That is the
# terminal shell itself, or the subshell `treehouse get` started in the
# leased worktree. Cygwin publishes each process cwd at /proc/<pid>/cwd.
fm_windows_console_cwd() {  # <winpid>
  local winpid=$1 rows newest proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  rows=$(fm_windows_ps_rows) || return 1
  newest=$(printf '%s\n' "$rows" | awk -v winpid="$winpid" '
    { pid[NR] = $1; tty[NR] = $4; cmd[NR] = $6 }
    $3 == winpid && $5 == 1 { shell = $1; console = $4 }
    END {
      if (shell == "") exit 1
      best = shell
      if (console != "?")
        for (i = 1; i <= NR; i++)
          if (tty[i] == console && cmd[i] ~ /(^|\/)bash(\.exe)?$/ && pid[i] + 0 > best + 0) best = pid[i]
      print best
    }') || return 1
  [ -n "$newest" ] || return 1
  readlink "$proc_root/$newest/cwd" 2>/dev/null
}

# fm_windows_shell_commands: one line "<pid> <command>" for every process the
# MSYS shell whose Windows pid is <winpid> runs: its descendants through the
# MSYS parent chain, plus anything else on its console. Fails when the shell
# is not in the table.
fm_windows_shell_commands() {  # <winpid>
  local winpid=$1 rows
  rows=$(fm_windows_ps_rows) || return 1
  printf '%s\n' "$rows" | awk -v winpid="$winpid" '
    {
      pid[NR] = $1; ppid[NR] = $2; tty[NR] = $4
      line = $0
      for (f = 1; f <= 5; f++) sub(/^[^ ]+ /, "", line)
      cmd[NR] = line
    }
    $3 == winpid && $5 == 1 { shell = $1; console = $4; found++ }
    END {
      if (found != 1) exit 1
      mine[shell] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++)
          if (!(pid[i] in mine) && (ppid[i] in mine)) { mine[pid[i]] = 1; grew = 1 }
      } while (grew)
      for (i = 1; i <= NR; i++) {
        if (pid[i] == shell) continue
        if ((pid[i] in mine) || (console != "?" && tty[i] == console)) print pid[i], cmd[i]
      }
    }'
}
