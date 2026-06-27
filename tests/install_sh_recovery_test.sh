#!/bin/sh
# Focused installer recovery harness. Invoked by install_sh_test.sh and
# runnable directly: sh tests/install_sh_recovery_test.sh.

set -eu

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/guildos-daemon-install.sh"

FAIL_COUNT=0
PASS_COUNT=0
SANDBOX=""
ORIG_PATH="$PATH"
HOST_SH="/bin/sh"
INSTALL_RC=0
INSTALL_OUT=""
FAKE_DAEMON_FAIL_CMD=""
GUILDOS_DAEMON_RELEASE_TAG=""

make_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/install-sh-recovery-test.XXXXXXXX")"
    mkdir -p "$SANDBOX/home" "$SANDBOX/bin"
}

teardown_sandbox() {
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}

make_uname_fake() {
    cat >"$SANDBOX/bin/uname" <<'UNAME_EOF'
#!/bin/sh
case "$1" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *)  printf 'Linux\n' ;;
esac
UNAME_EOF
    chmod +x "$SANDBOX/bin/uname"
}

make_uname_macos_arm64() {
    cat >"$SANDBOX/bin/uname" <<'UNAME_EOF'
#!/bin/sh
case "$1" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *)  printf 'Darwin\n' ;;
esac
UNAME_EOF
    chmod +x "$SANDBOX/bin/uname"
}

plant_fake_daemon() {
    target_dir="$1"
    mkdir -p "$target_dir"
    cat >"$target_dir/daemon" <<DAEMON_EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    printf 'guildos-daemon 0.61.40\n'
    exit 0
fi
if [ "\${1:-}" = "setup" ] && [ "\${2:-}" = "--help" ]; then
    exit 0
fi
printf '%s\n' "\$*" >> "$SANDBOX/daemon_calls"
[ "\$1" = "\${FAKE_DAEMON_FAIL_CMD:-}" ] && exit 9
exit 0
DAEMON_EOF
    chmod +x "$target_dir/daemon"
}

sandbox_path() {
    printf '%s:%s' "$SANDBOX/bin" "$ORIG_PATH"
}

run_install_sh() {
    set +e
    INSTALL_OUT="$(
        HOME="$SANDBOX/home" \
        PATH="$(sandbox_path)" \
        FAKE_DAEMON_FAIL_CMD="${FAKE_DAEMON_FAIL_CMD:-}" \
        GUILDOS_DAEMON_RELEASE_TAG="${GUILDOS_DAEMON_RELEASE_TAG:-}" \
        sh "$INSTALL_SH" 2>&1
    )"
    INSTALL_RC=$?
    set -e
}

daemon_first_call() {
    head -1 "$SANDBOX/daemon_calls" 2>/dev/null || echo NONE
}

chain_order() {
    awk '{print $1}' "$SANDBOX/daemon_calls" | tr '\n' ' ' | sed 's/ $//'
}

assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual" >&2
    fi
}

assert_contains() {
    label="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*) PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label" ;;
        *) FAIL_COUNT=$((FAIL_COUNT + 1))
           printf '  FAIL %s\n    needle: %s\n    not found\n' "$label" "$needle" >&2 ;;
    esac
}

assert_not_contains() {
    label="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*) FAIL_COUNT=$((FAIL_COUNT + 1))
           printf '  FAIL %s\n    forbidden needle: %s\n    found\n' "$label" "$needle" >&2 ;;
        *) PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label" ;;
    esac
}

assert_file_absent() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    path should not exist: %s\n' "$label" "$path" >&2
    else
        PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label"
    fi
}

printf '\nR1: missing curl prints manual recovery path\n'
make_sandbox; make_uname_fake
cat >"$SANDBOX/bin/xdg-open" <<OPEN_EOF
#!/bin/sh
printf '%s\n' "\$1" > "$SANDBOX/opened_url"
exit 0
OPEN_EOF
chmod +x "$SANDBOX/bin/xdg-open"
set +e
INSTALL_OUT="$(HOME="$SANDBOX/home" PATH="$SANDBOX/bin" "$HOST_SH" "$INSTALL_SH" 2>&1)"
INSTALL_RC=$?
set -e
assert_eq "R1.1 exit code 4 when curl is missing" "4" "$INSTALL_RC"
assert_contains "R1.2 prints missing-curl explanation" "curl was not found" "$INSTALL_OUT"
assert_contains "R1.3 prints exact Linux asset basename" "guildos-daemon-linux-x86_64" "$INSTALL_OUT"
assert_contains "R1.4 prints concrete download URL" \
    "releases/latest/download/guildos-daemon-linux-x86_64" "$INSTALL_OUT"
assert_contains "R1.5 prints helper page URL" \
    "https://guildos.ai/daemon-install-help?asset=guildos-daemon-linux-x86_64" "$INSTALL_OUT"
assert_eq "R1.6 opens helper page with platform asset query" \
    "https://guildos.ai/daemon-install-help?asset=guildos-daemon-linux-x86_64" \
    "$(cat "$SANDBOX/opened_url")"
assert_contains "R1.7 prints chmod step with concrete daemon path" \
    "chmod +x \"$SANDBOX/home/.guildos/daemon/daemon\"" "$INSTALL_OUT"
assert_contains "R1.8 prints login step" '$HOME/.guildos/daemon/daemon login' "$INSTALL_OUT"
assert_contains "R1.9 prints setup step" '$HOME/.guildos/daemon/daemon setup' "$INSTALL_OUT"
assert_contains "R1.10 prints daemon run fallback" '$HOME/.guildos/daemon/daemon run' "$INSTALL_OUT"
assert_file_absent "R1.11 no daemon binary created before manual path" \
    "$SANDBOX/home/.guildos/daemon/daemon"
assert_file_absent "R1.12 no daemon calls when curl missing" "$SANDBOX/daemon_calls"
teardown_sandbox

printf '\nR2: setup failure is recoverable after login\n'
make_sandbox; make_uname_fake
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40"
FAKE_DAEMON_FAIL_CMD="setup"; run_install_sh; FAKE_DAEMON_FAIL_CMD=""
GUILDOS_DAEMON_RELEASE_TAG=""
assert_eq "R2.1 exit code 0 on post-login setup failure" "0" "$INSTALL_RC"
assert_contains "R2.2 login chained before setup failure" "login" "$(daemon_first_call)"
assert_contains "R2.3 prints machine-added partial success" \
    "The machine has been added" "$INSTALL_OUT"
assert_contains "R2.4 prints setup exit code reason" \
    "daemon setup exited with code 9" "$INSTALL_OUT"
assert_contains "R2.5 prints reachable re-run-setup hint" \
    '$HOME/.guildos/daemon/daemon setup' "$INSTALL_OUT"
assert_contains "R2.6 prints foreground run fallback" \
    '$HOME/.guildos/daemon/daemon run' "$INSTALL_OUT"
assert_contains "R2.7 prints systemctl status recovery hint" \
    "systemctl --user status" "$INSTALL_OUT"
teardown_sandbox

printf '\nR3: macOS setup failure is recoverable\n'
make_sandbox; make_uname_macos_arm64
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40"
FAKE_DAEMON_FAIL_CMD="setup"; run_install_sh; FAKE_DAEMON_FAIL_CMD=""
GUILDOS_DAEMON_RELEASE_TAG=""
assert_eq "R3.1 exit code 0 on post-login setup failure" "0" "$INSTALL_RC"
assert_eq "R3.2 macOS chains login then setup before failing" "login setup" "$(chain_order)"
assert_contains "R3.3 prints setup exit code reason" \
    "daemon setup exited with code 9" "$INSTALL_OUT"
assert_contains "R3.4 prints reachable setup retry" \
    '$HOME/.guildos/daemon/daemon setup' "$INSTALL_OUT"
assert_contains "R3.5 prints foreground run fallback" \
    '$HOME/.guildos/daemon/daemon run' "$INSTALL_OUT"
assert_not_contains "R3.6 macOS setup failure does not print systemctl" \
    "systemctl --user status" "$INSTALL_OUT"
teardown_sandbox

printf '\n----\n'
printf 'RECOVERY PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
