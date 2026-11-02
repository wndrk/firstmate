#!/usr/bin/env bash
# bin/fm-windows-setup.sh on a simulated Git Bash host (docs/windows.md): a
# fake uname reports MINGW and a fake cygpath maps the Git for Windows root,
# so a Unix runner proves the Herdr config.toml edits, the ~/.bashrc block,
# idempotence, check-only mode, the --force rule for a conflicting shell, and
# the refusal off Windows. The script runs from a copied Firstmate root so its
# config/backend write never touches this checkout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-windows-setup)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_GIT="$TMP_ROOT/git-for-windows"
mkdir -p "$FAKE_GIT/bin"
: >"$FAKE_GIT/bin/bash.exe"
mkdir -p "$FAKE_GIT/usr/bin"
: >"$FAKE_GIT/usr/bin/bash.exe"

cat >"$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
cat >"$FAKEBIN/cygpath" <<SH
#!/usr/bin/env bash
mode=\$1
shift
[ "\${1:-}" != -- ] || shift
case "\$mode:\$1" in
  -w:/) printf '%s\n' 'C:\\Git' ;;
  -u:'C:\\Git\\bin\\bash.exe') printf '%s\n' '$FAKE_GIT/bin/bash.exe' ;;
  -u:'C:\\Git\\usr\\bin\\bash.exe') printf '%s\n' '$FAKE_GIT/usr/bin/bash.exe' ;;
  *) printf '%s\n' "\$1" ;;
esac
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/cygpath"

# A copied Firstmate root: the setup derives ROOT from its own location.
FM="$TMP_ROOT/firstmate"
mkdir -p "$FM/bin"
cp "$ROOT/bin/fm-windows-setup.sh" "$FM/bin/"
cp -R "$ROOT/bin/windows" "$FM/bin/windows"
git -C "$FM" init -q
git -C "$FM" add -A >/dev/null 2>&1

# setup runs the Herdr 1 (herdr.exe) form; setup_hc runs the herdr-core form
# with a fake herdr-core on PATH.
setup() {  # <home> [args...]
  local home=$1
  shift
  HOME="$home" APPDATA="$home/AppData/Roaming" HERDR_CONFIG_PATH='' XDG_CONFIG_HOME='' \
    PATH="$FAKEBIN:$PATH" bash "$FM/bin/fm-windows-setup.sh" --backend herdr "$@"
}

setup_hc() {  # <home> [args...]
  local home=$1
  shift
  HOME="$home" APPDATA="$home/AppData/Roaming" HERDR_CONFIG_PATH='' XDG_CONFIG_HOME='' \
    PATH="$HC_FAKEBIN:$FAKEBIN:$PATH" bash "$FM/bin/fm-windows-setup.sh" "$@"
}

HC_FAKEBIN="$TMP_ROOT/hc-bin"
mkdir -p "$HC_FAKEBIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo "hc 0.2.0"' >"$HC_FAKEBIN/herdr-core"
chmod +x "$HC_FAKEBIN/herdr-core"

fresh_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/AppData/Roaming"
  printf '%s\n' "$home"
}

config_of() { printf '%s\n' "$1/AppData/Roaming/herdr/config.toml"; }
hc_config_of() { printf '%s\n' "$1/AppData/Roaming/herdr-core/config.toml"; }
HC_SHELL_LINE="shell = ['C:\\Git\\usr\\bin\\bash.exe', '--login', '-i']"

test_apply_writes_herdr_shell_and_bashrc() {
  local home out config
  home=$(fresh_home apply)
  out=$(setup "$home" 2>&1)
  config=$(config_of "$home")
  [ -f "$config" ] || fail "apply did not create the Herdr config: $out"
  grep -qx '\[terminal\]' "$config" || fail "config lacks [terminal]: $(cat "$config")"
  grep -qx "default_shell = 'C:\\\\Git\\\\usr\\\\bin\\\\bash.exe'" "$config" \
    || fail "config does not point default_shell at Git Bash: $(cat "$config")"
  grep -qx 'shell_mode = "login"' "$config" || fail "config lacks shell_mode login: $(cat "$config")"
  grep -qF "export PATH=\"$FM/bin/windows:\$PATH\"" "$home/.bashrc" \
    || fail "bashrc block lacks the shim PATH: $out"
  grep -qx 'export SHELL=/usr/bin/bash' "$home/.bashrc" || fail "bashrc block lacks SHELL"
  grep -qF 'winsymlinks:sys' "$home/.bashrc" || fail "bashrc block lacks MSYS winsymlinks:sys"
  grep -qF '. ~/.bashrc' "$home/.bash_profile" || fail "bash_profile does not source bashrc"
  [ "$(cat "$FM/config/backend")" = herdr ] || fail "config/backend was not set to herdr"
  pass "apply sets Herdr's pane shell to Git Bash, writes the bashrc block, and selects herdr"
}

test_apply_is_idempotent_and_keeps_other_settings() {
  local home config before
  home=$(fresh_home idem)
  config=$(config_of "$home")
  mkdir -p "${config%/*}"
  printf '%s\n' '[ui]' 'host_cursor = "native"' '' '[terminal]' 'new_cwd = "follow"' '' '[server]' 'x = 1' >"$config"
  printf '%s\n' 'alias ll="ls -l"' >"$home/.bashrc"
  setup "$home" >/dev/null 2>&1
  before=$(cat "$config" "$home/.bashrc")
  setup "$home" >/dev/null 2>&1
  [ "$(cat "$config" "$home/.bashrc")" = "$before" ] || fail "a second apply changed the files"
  grep -qx 'host_cursor = "native"' "$config" || fail "apply dropped [ui] settings"
  grep -qx 'new_cwd = "follow"' "$config" || fail "apply dropped existing [terminal] keys"
  [ "$(grep -c '^\[terminal\]' "$config")" = 1 ] || fail "apply duplicated [terminal]: $(cat "$config")"
  awk '/^\[terminal\]/{t=1;next} /^\[/{t=0} t && /^default_shell/{f=1} END{exit !f}' "$config" \
    || fail "default_shell landed outside [terminal]: $(cat "$config")"
  grep -qx 'alias ll="ls -l"' "$home/.bashrc" || fail "apply dropped existing bashrc lines"
  [ "$(grep -c '>>> firstmate windows' "$home/.bashrc")" = 1 ] || fail "apply duplicated the bashrc block"
  pass "apply is idempotent and preserves unrelated config and bashrc content"
}

test_check_mode_changes_nothing() {
  local home rc=0
  home=$(fresh_home check)
  setup "$home" --check >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "check mode on an unprepared host exited $rc, expected 1"
  [ ! -e "$(config_of "$home")" ] || fail "check mode wrote the Herdr config"
  [ ! -e "$home/.bashrc" ] || fail "check mode wrote ~/.bashrc"
  pass "--check reports missing setup without writing anything"
}

test_conflicting_shell_needs_force() {
  local home config
  home=$(fresh_home force)
  config=$(config_of "$home")
  mkdir -p "${config%/*}"
  printf '%s\n' '[terminal]' "default_shell = 'pwsh.exe'" >"$config"
  setup "$home" >/dev/null 2>&1
  grep -qx "default_shell = 'pwsh.exe'" "$config" || fail "apply replaced a user-chosen shell without --force"
  setup "$home" --force >/dev/null 2>&1
  grep -qx "default_shell = 'C:\\\\Git\\\\usr\\\\bin\\\\bash.exe'" "$config" \
    || fail "--force did not replace the conflicting shell: $(cat "$config")"
  [ "$(grep -c '^default_shell' "$config")" = 1 ] || fail "--force left two default_shell lines"
  pass "a conflicting default_shell is replaced only with --force"
}

test_refuses_off_windows() {
  local rc=0
  HOME="$TMP_ROOT/unix" bash "$FM/bin/fm-windows-setup.sh" --check >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "setup off Windows exited $rc, expected 2"
  pass "setup refuses to run off Git Bash on Windows"
}

test_git_launcher_shell_is_upgraded() {
  local home config
  home=$(fresh_home launcher)
  config=$(config_of "$home")
  mkdir -p "${config%/*}"
  printf '%s\n' '[terminal]' "default_shell = 'C:\\Git\\bin\\bash.exe'" >"$config"
  setup "$home" >/dev/null 2>&1
  grep -qx "default_shell = 'C:\\\\Git\\\\usr\\\\bin\\\\bash.exe'" "$config" \
    || fail "apply kept Git's bin\\bash.exe launcher: $(cat "$config")"
  pass "Git's bin\\bash.exe launcher is upgraded to usr\\bin\\bash.exe without --force"
}

test_hc_backend_sets_herdr_core_shell() {
  local home config before
  rm -f "$FM/config/backend"
  home=$(fresh_home hc)
  setup_hc "$home" >/dev/null 2>&1
  config=$(hc_config_of "$home")
  [ -f "$config" ] || fail "hc apply did not create herdr-core's config"
  [ "$(head -1 "$config")" = "$HC_SHELL_LINE" ] || fail "herdr-core shell is not Git Bash as a login shell: $(cat "$config")"
  [ ! -e "$(config_of "$home")" ] || fail "hc apply wrote Herdr 1's config"
  [ "$(cat "$FM/config/backend")" = hc ] || fail "herdr-core on PATH did not select backend hc"
  # shellcheck disable=SC2016 # the literal line the block carries
  grep -qF 'export FM_BACKEND="${FM_BACKEND:-hc}"' "$home/.bashrc" || fail "bashrc block does not default to hc"
  printf '%s\n' '[ui]' 'x = 1' >>"$config"
  before=$(cat "$config")
  setup_hc "$home" >/dev/null 2>&1
  [ "$(cat "$config")" = "$before" ] || fail "a second hc apply changed herdr-core's config"
  printf '%s\n' "shell = ['pwsh.exe']" '[ui]' >"$config"
  setup_hc "$home" >/dev/null 2>&1
  [ "$(head -1 "$config")" = "shell = ['pwsh.exe']" ] || fail "hc apply replaced a user-chosen shell without --force"
  setup_hc "$home" --force >/dev/null 2>&1
  [ "$(head -1 "$config")" = "$HC_SHELL_LINE" ] || fail "--force did not replace the herdr-core shell: $(cat "$config")"
  [ "$(grep -c '^shell' "$config")" = 1 ] || fail "--force left two shell lines"
  pass "backend hc sets herdr-core's shell to Git Bash, selects hc, and keeps a chosen shell without --force"
}

test_explicit_backend_switches_config_backend() {
  local home
  home=$(fresh_home switch)
  printf 'herdr\n' >"$FM/config/backend"
  setup_hc "$home" >/dev/null 2>&1
  [ "$(cat "$FM/config/backend")" = herdr ] || fail "an existing config/backend changed without --backend"
  setup_hc "$home" --backend hc >/dev/null 2>&1
  [ "$(cat "$FM/config/backend")" = hc ] || fail "--backend hc did not switch config/backend"
  pass "config/backend changes only when --backend names another backend"
}

# The end-to-end probe only runs on the windows-latest workflow; here it must
# at least parse, so a syntax slip fails on every runner.
test_windows_probe_parses() {
  bash -n "$ROOT/bin/fm-windows-herdr-probe.sh" \
    || fail "bin/fm-windows-herdr-probe.sh does not parse"
  bash -n "$ROOT/bin/fm-windows-hc-probe.sh" \
    || fail "bin/fm-windows-hc-probe.sh does not parse"
  pass "the Windows Herdr and herdr-core probes parse"
}

fm_test_run \
  test_apply_writes_herdr_shell_and_bashrc \
  test_apply_is_idempotent_and_keeps_other_settings \
  test_check_mode_changes_nothing \
  test_conflicting_shell_needs_force \
  test_git_launcher_shell_is_upgraded \
  test_refuses_off_windows \
  test_hc_backend_sets_herdr_core_shell \
  test_explicit_backend_switches_config_backend \
  test_windows_probe_parses
