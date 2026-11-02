# Native Windows with Herdr

This page covers running Firstmate on native Windows, without WSL, on the Herdr backend.
Operators on Windows who want a crew in Herdr need it.

## How it works

Firstmate stays a bash distro on Windows.
It runs under Git Bash from Git for Windows and drives the native Windows builds of its tools:

| Piece | Windows form |
| --- | --- |
| Shell for Firstmate and every worker pane | Git Bash: Git for Windows' `usr\bin\bash.exe` |
| Session backend | `herdr.exe` 0.9.5 or newer, with native ConPTY panes |
| Worktrees | `treehouse.exe` |
| JSON | `jq.exe` 1.7 or newer, run through the `bin/windows/jq` shim |
| Optional Python helpers | Python 3 from python.org, run through the `bin/windows/python3` shim |

Herdr starts PowerShell in new panes by default on Windows.
Firstmate types bash commands into its panes, so Herdr's `[terminal] default_shell` must point at Git Bash.
It must be Git's `usr\bin\bash.exe`, not the `bin\bash.exe` launcher: the launcher starts the real bash one process down, which hides that bash's process id, children, and working directory from Herdr and from Firstmate.
[`bin/fm-windows-setup.sh`](../bin/fm-windows-setup.sh) sets that up.

## Setup

1. Install the tools from PowerShell:

   ```powershell
   winget install Git.Git jqlang.jq OpenJS.NodeJS.LTS GitHub.cli Python.Python.3.12
   powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
   powershell -c "irm https://kunchenguid.github.io/treehouse/install.ps1 | iex"
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
   bin/fm-windows-setup.sh
   ```

   It checks the tools and the checkout, then:

   - sets Herdr's `[terminal] default_shell` to Git's `usr\bin\bash.exe` and `shell_mode = "login"` in `%APPDATA%\herdr\config.toml` (it upgrades Git's `bin\bash.exe` launcher, and never replaces any other shell without `--force`);
   - adds one marked block to `~/.bashrc` that puts `bin/windows` first on `PATH`, records the real `jq.exe`, exports `SHELL=/usr/bin/bash`, sets `MSYS=winsymlinks:sys`, and defaults `FM_BACKEND` to `herdr`;
   - creates `~/.bash_profile` that sources `~/.bashrc` when you have none;
   - writes `config/backend` as `herdr` when it is absent.

   `bin/fm-windows-setup.sh --check` reports the same items without changing anything.

5. Open Windows Terminal, run `herdr`, and start your agent (for example `claude`) in a Herdr pane inside the Firstmate checkout.
   Firstmate auto-detects Herdr there through `HERDR_ENV=1`.

## What changes on Windows

These adapter behaviors switch on automatically under Git Bash (`fm_backend_herdr_windows_host` in [`bin/backends/herdr.sh`](../bin/backends/herdr.sh)); `FM_BACKEND_HERDR_WINDOWS=1` or `0` overrides the detection for tests.

| Area | Unix behavior | Windows behavior |
| --- | --- | --- |
| Control socket | Unix domain socket path | Named pipe, opened by [`bin/backends/herdr_transport.py`](../bin/backends/herdr_transport.py); the pipe name is its own identity |
| Helper output | LF | The Herdr Python helpers force LF on stdout; `bin/windows/jq` runs `jq -b` |
| Pane cwd | Herdr's `foreground_cwd` | Herdr 0.9.5 reports no `foreground_cwd` on Windows, so the cwd of the newest bash on the pane's console comes from Git Bash's `ps -W` and `/proc/<pid>/cwd`, which also follows the subshell `treehouse get` opens |
| Idle-shell proof | Foreground process group plus `ps` | Herdr proves the pane's one foreground process is its bash; `ps -W` maps that Windows pid to the MSYS bash and proves no child process and nothing else on its console |
| Pane-death close | `SIGHUP`, then `SIGKILL` to the shell pid | `exit` is submitted to the proved idle shell; there is no forced escalation |
| Presentation lock directory | Must read back as mode `0700` | Owner check only, because Git Bash mounts NTFS with `noacl` |
| Symlink locks | Native | `MSYS=winsymlinks:sys` makes `ln -s` create real links instead of copies |

## Limits

- Stale-lock reaping that needs `lsof` stays conservative: Git Bash has no `lsof`, so Firstmate never steals a lock it cannot prove abandoned.
- Python scripts outside the Herdr helpers still print CRLF on Windows; features that parse their output may need the same `lf_stdout` treatment.
- `herdr terminal attach` and live server handoff are not available on Windows (Herdr's own limits).
- The extension launcher's POSIX process-group cleanup (`bin/fm-extension.mjs`) remains unsupported on Windows.
- Other backends (tmux, zellij, cmux, and the rest) are not supported on native Windows.

## Verification

[`.github/workflows/windows-herdr.yml`](../.github/workflows/windows-herdr.yml) runs on a `windows-latest` runner.
It installs Herdr, Treehouse, and jq with their official Windows installers, applies `bin/fm-windows-setup.sh`, runs the transport unit tests in [`tests/fm-backend-herdr-eventwait.test.py`](../tests/fm-backend-herdr-eventwait.test.py), and runs [`bin/fm-windows-herdr-probe.sh`](../bin/fm-windows-herdr-probe.sh).
The probe checks, against a private Herdr session: that panes start Git Bash, typed commands run, the idle-shell proof accepts an idle pane and refuses a busy one, the foreground cwd resolves, the named-pipe socket path is accepted, a reported `blocked` edge arrives over the push-event stream, Treehouse leases a worktree Git can read, and an idle split pane closes through its own shell exit.
The older manual [`.github/workflows/windows-herdr-spike.yml`](../.github/workflows/windows-herdr-spike.yml) measurement remains available through `workflow_dispatch`.
