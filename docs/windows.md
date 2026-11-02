# Native Windows with Herdr

This page covers running Firstmate on native Windows, without WSL, with Herdr.
Operators on Windows who want a crew in Herdr need it.

Herdr comes in two forms, and Firstmate supports both on Windows:

| Herdr form | What it is | Firstmate backend |
| --- | --- | --- |
| The Herdr app (`herdr-app`) | A desktop window; its terminals run in herdr-core (`herdr-core.exe`, alias `hc`), which keeps them alive when the window closes | `hc` ([`hc-backend.md`](hc-backend.md)) |
| Herdr 1 (`herdr.exe`) | A terminal multiplexer that runs inside Windows Terminal | `herdr` ([`herdr-backend.md`](herdr-backend.md)) |

With the Herdr app, Firstmate starts each worker as a herdr-core terminal labeled for the app, so the app shows a home's workers in one space with one tab each.

## How it works

Firstmate stays a bash distro on Windows.
It runs under Git Bash from Git for Windows and drives the native Windows builds of its tools:

| Piece | Windows form |
| --- | --- |
| Shell for Firstmate and every worker terminal | Git Bash: Git for Windows' `usr\bin\bash.exe` |
| Terminal host | herdr-core (under the Herdr app), or `herdr.exe` 0.9.5 or newer; both use native ConPTY |
| Worktrees | `treehouse.exe` |
| JSON | `jq.exe` 1.7 or newer, run through the `bin/windows/jq` shim |
| Optional Python helpers (Herdr 1 only) | Python 3 from python.org, run through the `bin/windows/python3` shim |

Both Herdr forms start PowerShell in new terminals by default on Windows.
Firstmate types bash commands into its terminals, so the shell must be Git Bash: herdr-core's top-level `shell` setting, or Herdr 1's `[terminal] default_shell`.
It must be Git's `usr\bin\bash.exe`, not the `bin\bash.exe` launcher: the launcher starts the real bash one process down, which hides that bash's process id, children, and working directory from Herdr and from Firstmate.
[`bin/fm-windows-setup.sh`](../bin/fm-windows-setup.sh) sets that up.

## Setup

1. Install the tools from PowerShell:

   ```powershell
   winget install Git.Git jqlang.jq OpenJS.NodeJS.LTS GitHub.cli
   powershell -c "irm https://kunchenguid.github.io/treehouse/install.ps1 | iex"
   # The Herdr app; its installer also installs herdr-core:
   irm https://releases.herdr.dev/app/install.ps1 | iex
   ```

   For Herdr 1 instead, install `herdr.exe` and Python:

   ```powershell
   winget install Python.Python.3.12
   powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
   ```

2. Turn on Windows Developer Mode (Settings, System, For developers) so Git can create the repository's symlinks.

3. Clone from Git Bash with symlinks enabled:

   ```bash
   git clone -c core.symlinks=true https://github.com/<you>/firstmate.git
   cd firstmate
   ```

   The repository's `.gitattributes` keeps every text file LF even though Git for Windows defaults to `core.autocrlf=true`.

4. Run the setup from Git Bash:

   ```bash
   bin/fm-windows-setup.sh --backend hc      # the Herdr app
   bin/fm-windows-setup.sh --backend herdr   # Herdr 1
   ```

   Without `--backend`, an existing `config/backend` decides; otherwise it picks `hc` when herdr-core is installed.
   It checks the tools and the checkout, then:

   - for `hc`, sets herdr-core's `shell = ['<Git>\usr\bin\bash.exe', '--login', '-i']` in `%APPDATA%\herdr-core\config.toml`;
   - for `herdr`, sets Herdr's `[terminal] default_shell` to Git's `usr\bin\bash.exe` and `shell_mode = "login"` in `%APPDATA%\herdr\config.toml`;
   - in both cases it upgrades Git's `bin\bash.exe` launcher and never replaces any other shell without `--force`;
   - adds one marked block to `~/.bashrc` that puts `bin/windows` first on `PATH`, records the real `jq.exe`, exports `SHELL=/usr/bin/bash`, sets `MSYS=winsymlinks:sys`, and defaults `FM_BACKEND` to the chosen backend;
   - creates `~/.bash_profile` that sources `~/.bashrc` when you have none;
   - writes `config/backend` when it is absent, or when `--backend` names another backend.

   `bin/fm-windows-setup.sh --check` reports the same items without changing anything.

5. Start your agent (for example `claude`) inside the Firstmate checkout:

   - **Herdr app:** open Herdr, open a terminal in the Firstmate checkout, and start the agent there. Workers appear in the app in a space named `fm-<home>`, one tab per worker. hc is never auto-detected, so `config/backend` (written by the setup) selects it.
   - **Herdr 1:** open Windows Terminal, run `herdr`, and start the agent in a Herdr pane. Firstmate auto-detects Herdr there through `HERDR_ENV=1`.

## What changes on Windows

These adapter behaviors switch on automatically under Git Bash (`fm_windows_host` in [`bin/fm-windows-proc-lib.sh`](../bin/fm-windows-proc-lib.sh)); `FM_BACKEND_HC_WINDOWS` or `FM_BACKEND_HERDR_WINDOWS` set to `1` or `0` overrides the detection for tests.

On a Windows pseudo console a terminal has no foreground process group, so both herdr-core and `herdr.exe` report the terminal's first program, the Git Bash shell, for its whole life, even while it runs a command.
Firstmate therefore reads what that shell runs, and which folder it is in, from Git Bash's own process table (`ps -W` and `/proc/<pid>/cwd`).

### herdr-core (the Herdr app)

| Area | Unix behavior | Windows behavior |
| --- | --- | --- |
| Agent state | hc's foreground process plus its process group from `ps` | Every process under the terminal's shell, or on its console, from `ps -W`; a harness is found by its program name, such as `claude.exe` |
| Current path | hc's foreground `cwd` | The cwd of the newest bash on the terminal's console, which follows the subshell `treehouse get` opens |
| Arguments to `hc` | Passed as they are | Passed as they are too: Git Bash's automatic POSIX-to-Windows path rewriting is turned off for every `hc` call, so typed text never changes, and `--cwd` is converted explicitly |

### Herdr 1 (`herdr.exe`)

| Area | Unix behavior | Windows behavior |
| --- | --- | --- |
| Control socket | Unix domain socket path | Herdr reports `...\herdr\sessions\<name>\herdr.sock` but serves a named pipe named by that whole path (`\\.\pipe\C:\...\herdr.sock`); [`bin/backends/herdr_transport.py`](../bin/backends/herdr_transport.py) opens that pipe |
| Helper output | LF | The Herdr Python helpers force LF on stdout; `bin/windows/jq` runs `jq -b` |
| Pane cwd | Herdr's `foreground_cwd` | Herdr 0.9.5 reports no `foreground_cwd` on Windows, so the cwd of the newest bash on the pane's console comes from Git Bash's `ps -W` and `/proc/<pid>/cwd`, which also follows the subshell `treehouse get` opens |
| Idle-shell proof | Foreground process group plus `ps` | Herdr proves the pane's one foreground process is its bash; `ps -W` maps that Windows pid to the MSYS bash and proves no child process and nothing else on its console |
| Pane-death close | `SIGHUP`, then `SIGKILL` to the shell pid | `exit` is submitted to the proved idle shell; there is no forced escalation |
| Presentation lock directory | Must read back as mode `0700` | Owner check only, because Git Bash mounts NTFS with `noacl` |
| Symlink locks | Native | `MSYS=winsymlinks:sys` makes `ln -s` create real links instead of copies |

## Limits

- With the Herdr app, a harness that runs as `node.exe` plus a script (an npm-installed Claude Code, for example) reads as an unknown program rather than a live agent, so recovery stays conservative; Claude Code's native installer (`claude.exe`) is recognized.
- Stale-lock reaping that needs `lsof` stays conservative: Git Bash has no `lsof`, so Firstmate never steals a lock it cannot prove abandoned.
- Python scripts outside the Herdr helpers still print CRLF on Windows; features that parse their output may need the same `lf_stdout` treatment.
- `herdr terminal attach` and live server handoff are not available on Windows (Herdr's own limits).
- The extension launcher's POSIX process-group cleanup (`bin/fm-extension.mjs`) remains unsupported on Windows.
- Other backends (tmux, zellij, cmux, and the rest) are not supported on native Windows.
- The Herdr app window itself is not exercised in CI; the probe drives herdr-core, which the app shows.

## Verification

[`.github/workflows/windows-herdr.yml`](../.github/workflows/windows-herdr.yml) runs one job per Herdr form on a `windows-latest` runner.
Each installs its tools with their official Windows installers and applies `bin/fm-windows-setup.sh`.

The herdr-core job runs [`bin/fm-windows-hc-probe.sh`](../bin/fm-windows-hc-probe.sh) against a private herdr-core session.
It checks that the core starts and answers the protocol handshake, that a task terminal starts Git Bash with the Herdr app's space and tab labels, that typed commands run, that the current path follows `cd` and a subshell, that agent state reads an idle shell as dead, a running program as ambiguous, and a running `claude.exe` as alive, that a submitted line runs, that Treehouse leases a worktree, and that the terminal closes.

The Herdr 1 job runs the transport unit tests in [`tests/fm-backend-herdr-eventwait.test.py`](../tests/fm-backend-herdr-eventwait.test.py) and [`bin/fm-windows-herdr-probe.sh`](../bin/fm-windows-herdr-probe.sh).
That probe checks, against a private Herdr session: that panes start Git Bash, typed commands run, the idle-shell proof accepts an idle pane and refuses a busy one, the foreground cwd resolves, the named-pipe socket path is accepted, a reported `blocked` edge arrives over the push-event stream, Treehouse leases a worktree Git can read, and an idle split pane closes through its own shell exit.
The older manual [`.github/workflows/windows-herdr-spike.yml`](../.github/workflows/windows-herdr-spike.yml) measurement remains available through `workflow_dispatch`.
