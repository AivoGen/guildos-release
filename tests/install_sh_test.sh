#!/bin/sh
# install_sh_test.sh — POSIX behavioral harness for
# `scripts/guildos-daemon-install.sh` (task #1344 PR8; #1748 P1 login→setup).
#
# Architect Q5 ruling msg=03ae05ce (a): guildos-release self-tests its one
# canonical script. shellcheck (b) is static-only — misses behavioral
# correctness (chain order + no-service-manager + idempotency + recovery).
#
# Strategy: build a sandbox $HOME with HOME=, PATH= shimmed so `curl` + `uname`
# are deterministic fakes. The fake `daemon` APPENDS each call's argv (one line
# per invocation) to `$SANDBOX/daemon_calls`, so we can assert the login→setup
# ORDER; it fails a chosen subcommand when FAKE_DAEMON_FAIL_CMD matches, driving
# the recovery paths.
#
# Run:  sh tests/install_sh_test.sh   (exits 0 on PASS, non-zero on FAIL)

set -eu

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/guildos-daemon-install.sh"

if [ ! -f "$INSTALL_SH" ]; then
    printf 'FATAL: install.sh not found at %s\n' "$INSTALL_SH" >&2
    exit 99
fi

FAIL_COUNT=0
PASS_COUNT=0

SANDBOX=""
make_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/install-sh-test.XXXXXXXX")"
    mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/curl_log"
}
teardown_sandbox() {
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}

# Fake `uname` (Linux-x86_64 so the platform gate passes).
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

# Fake `uname` for macOS arm64.
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

# Fake `uname` for an unsupported platform (forces exit 3).
make_uname_unsupported() {
    cat >"$SANDBOX/bin/uname" <<'UNAME_EOF'
#!/bin/sh
case "$1" in
    -s) printf 'FreeBSD\n' ;;
    -m) printf 'riscv64\n' ;;
    *)  printf 'FreeBSD\n' ;;
esac
UNAME_EOF
    chmod +x "$SANDBOX/bin/uname"
}

# Fake `curl` that records argv + url then plants the call-recording daemon
# (below) into the `-o` download target — so the post-download login→setup
# chain is observable. Shared by the download-path tests (T1/T2).
make_curl_planter() {
    cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
for arg in "\$@"; do
    if [ "\$arg" = "-w" ]; then
        printf 'https://github.com/AivoGen/guildos-release/releases/tag/v0.61.40'
        exit 0
    fi
done
printf '%s\n' "\$@" > "$SANDBOX/curl_log/argv"
out_path=""
url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out_path="\$2"; shift 2 ;;
        --*|-*) shift ;;
        *)  url="\$1"; shift ;;
    esac
done
printf '%s\n' "\$url" > "$SANDBOX/curl_log/url"
if [ -n "\$out_path" ]; then
    cat >"\$out_path" <<'DAEMON_PAYLOAD'
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
DAEMON_PAYLOAD
fi
exit 0
CURL_EOF
    chmod +x "$SANDBOX/bin/curl"
}

# Pre-plant the call-recording daemon at the canonical path (binary-present
# tests skip download). Appends each call's argv; fails the subcommand named by
# FAKE_DAEMON_FAIL_CMD.
plant_fake_daemon() {
    target_dir="$1"
    version="${2:-0.61.40}"
    supports_setup="${3:-yes}"
    mkdir -p "$target_dir"
    cat >"$target_dir/daemon" <<DAEMON_EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
    printf 'guildos-daemon %s\n' "$version"
    exit 0
fi
if [ "\${1:-}" = "setup" ] && [ "\${2:-}" = "--help" ]; then
    [ "$supports_setup" = "yes" ] && exit 0
    exit 2
fi
printf '%s\n' "\$*" >> "$SANDBOX/daemon_calls"
[ "\$1" = "\${FAKE_DAEMON_FAIL_CMD:-}" ] && exit 9
exit 0
DAEMON_EOF
    chmod +x "$target_dir/daemon"
}

sandbox_path() {
    printf '%s:%s' "$SANDBOX/bin" "${ORIG_PATH:-$PATH}"
}

# Run install.sh under the sandbox; forwards FAKE_DAEMON_FAIL_CMD so recovery
# paths can be driven. Returns exit code in INSTALL_RC, output in INSTALL_OUT.
INSTALL_RC=0
INSTALL_OUT=""
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

# Convenience accessors for the recorded daemon calls.
daemon_calls() { cat "$SANDBOX/daemon_calls" 2>/dev/null || echo NONE; }
daemon_first_call() { head -1 "$SANDBOX/daemon_calls" 2>/dev/null || echo NONE; }

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
           printf '  FAIL %s\n    needle: %s\n    not found in haystack\n' "$label" "$needle" >&2 ;;
    esac
}
assert_not_contains() {
    label="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*) FAIL_COUNT=$((FAIL_COUNT + 1))
           printf '  FAIL %s\n    forbidden needle: %s\n    found in haystack\n' "$label" "$needle" >&2 ;;
        *) PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label" ;;
    esac
}
assert_file_exists() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label"
    else FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL %s\n    path missing: %s\n' "$label" "$path" >&2; fi
}
assert_file_absent() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL %s\n    path should not exist: %s\n' "$label" "$path" >&2
    else PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label"; fi
}

ORIG_PATH="$PATH"
HOST_SH="/bin/sh"
FAKE_DAEMON_FAIL_CMD=""
GUILDOS_DAEMON_RELEASE_TAG=""

# ============================================================================
# T1: happy path — fresh install, binary absent
#   - downloads from `latest`; atomic install (no .tmp.* leftover)
#   - chains login THEN setup (one command); setup carries NO --company-id
#   - prints the "installed, paired, and started" success message
# ============================================================================
printf '\nT1: happy path (fresh install, latest tag)\n'
make_sandbox; make_uname_fake; make_curl_planter
run_install_sh
assert_eq "T1.1 exit code 0" "0" "$INSTALL_RC"
assert_file_exists "T1.2 daemon binary installed at canonical path" \
    "$SANDBOX/home/.guildos/daemon/daemon"
assert_contains "T1.3 curl URL points at latest" \
    "releases/latest/download/guildos-daemon-linux-x86_64" "$(cat "$SANDBOX/curl_log/url")"
assert_eq "T1.4 chain order is exactly login then setup" "login setup" \
    "$(awk '{print $1}' "$SANDBOX/daemon_calls" | tr '\n' ' ' | sed 's/ $//')"
assert_not_contains "T1.5 setup chained WITHOUT --company-id (pairing binds company)" \
    "--company-id" "$(daemon_calls)"
assert_contains "T1.7 prints one-command success message" \
    "installed, paired, and started" "$INSTALL_OUT"
leftover_tmp=$(ls "$SANDBOX/home/.guildos/daemon/"daemon.tmp.* 2>/dev/null || true)
assert_eq "T1.8 no leftover daemon.tmp.* file" "" "$leftover_tmp"
teardown_sandbox

# ============================================================================
# T2: env override — GUILDOS_DAEMON_RELEASE_TAG=v0.60.0 → pinned tag URL
# ============================================================================
printf '\nT2: env override GUILDOS_DAEMON_RELEASE_TAG\n'
make_sandbox; make_uname_fake; make_curl_planter
set +e
INSTALL_OUT="$(
    HOME="$SANDBOX/home" PATH="$(sandbox_path)" \
    GUILDOS_DAEMON_RELEASE_TAG="v0.60.0" sh "$INSTALL_SH" 2>&1
)"
INSTALL_RC=$?
set -e
assert_eq "T2.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T2.2 URL uses pinned v0.60.0 tag" \
    "releases/download/v0.60.0/guildos-daemon-linux-x86_64" "$(cat "$SANDBOX/curl_log/url")"
assert_not_contains "T2.3 URL does NOT contain /latest/" "/latest/" "$(cat "$SANDBOX/curl_log/url")"
teardown_sandbox

# ============================================================================
# T3: binary reuse/latest edge cases live in a sibling harness so this
# canonical broad harness stays below the touched-file line cap.
# ============================================================================
printf '\nT3: binary reuse/latest split harness\n'
set +e
sh "$TEST_DIR/install_sh_reuse_test.sh"
split_rc=$?
set -e
assert_eq "T3.1 split harness exit code 0" "0" "$split_rc"

# ============================================================================
# T4: no service-manager logic — shell must not INVOKE systemctl/systemd.
#   Static check on EXECUTABLE code only: strip comments + every quoted heredoc
#   body (heredoc content is OUTPUT to the operator — recovery hints legitimately
#   mention `systemctl` — not script execution).
# ============================================================================
printf '\nT4: no service-manager logic in shell\n'
code_only="$(awk '
    in_heredoc { if ($0 ~ ("^[[:space:]]*" marker "$")) in_heredoc = 0; next }
    /^[[:space:]]*cat .*<<.[A-Za-z_][A-Za-z0-9_]*./ {
        marker = $0; sub(/.*<<./, "", marker); sub(/[^A-Za-z0-9_].*/, "", marker)
        in_heredoc = 1; next
    }
    /^[[:space:]]*#/ { next }
    { print }
' "$INSTALL_SH")"
assert_not_contains "T4.1 no systemctl invocation in executable code" "systemctl " "$code_only"
assert_not_contains "T4.2 no systemd-run invocation" "systemd-run" "$code_only"
assert_not_contains "T4.3 no pgrep service-detection in executable code" "pgrep " "$code_only"
assert_not_contains "T4.4 no daemon_running() gate" "daemon_running" "$code_only"
assert_not_contains "T4.5 no --install-only flag (legacy bootstrap retired)" "--install-only" "$code_only"
assert_not_contains "T4.6 no --token argv plumbing" '"$TOKEN"' "$code_only"
assert_not_contains "T4.7 no --core-url argv plumbing" '"$CORE_URL"' "$code_only"
assert_not_contains "T4.8 no daemon.pid PID-file check" "daemon.pid" "$code_only"

# ============================================================================
# T5: download failure → exit 4, nothing chained
# ============================================================================
printf '\nT5: download failure exits non-zero\n'
make_sandbox; make_uname_fake
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
printf 'fake-curl: simulated failure\n' >&2
exit 22
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
run_install_sh
assert_eq "T5.1 exit code 4 on download failure" "4" "$INSTALL_RC"
assert_file_absent "T5.2 no daemon binary at canonical path" \
    "$SANDBOX/home/.guildos/daemon/daemon"
assert_file_absent "T5.3 nothing chained (no daemon_calls)" "$SANDBOX/daemon_calls"
assert_contains "T5.4 download failure error message" "download failed" "$INSTALL_OUT"
leftover_tmp=$(ls "$SANDBOX/home/.guildos/daemon/"daemon.tmp.* 2>/dev/null || true)
assert_eq "T5.5 no leftover daemon.tmp.* on download failure" "" "$leftover_tmp"
teardown_sandbox

# ============================================================================
# T6: macOS downloads darwin asset, chains login then setup, then prints the
# finalized foreground fallback. This prevents the paired-token `run` path.
# ============================================================================
printf '\nT6: macOS arm64 finalize-before-run variant\n'
make_sandbox; make_uname_macos_arm64; make_curl_planter
run_install_sh
assert_eq "T6.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T6.2 curl URL points at darwin-arm64 asset" \
    "releases/latest/download/guildos-daemon-darwin-arm64" "$(cat "$SANDBOX/curl_log/url")"
assert_eq "T6.3 chain order is exactly login then setup" "login setup" \
    "$(awk '{print $1}' "$SANDBOX/daemon_calls" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "T6.4 prints finalized success before foreground run guidance" \
    "installed, paired, and finalized" "$INSTALL_OUT"
assert_contains "T6.5 prints foreground run guidance only after setup succeeded" "daemon run" "$INSTALL_OUT"
teardown_sandbox

# ============================================================================
# T6b: unsupported platform → exit 3, no download attempted
# ============================================================================
printf '\nT6b: unsupported platform exits 3\n'
make_sandbox; make_uname_unsupported
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
touch "$SANDBOX/curl_log/INVOKED"
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
run_install_sh
assert_eq "T6b.1 exit code 3 on unsupported platform" "3" "$INSTALL_RC"
assert_file_absent "T6b.2 curl NOT invoked on platform reject" "$SANDBOX/curl_log/INVOKED"
assert_contains "T6b.3 platform error message" "unsupported platform" "$INSTALL_OUT"
teardown_sandbox

# ============================================================================
# T6c/T10: recovery-path cases live in a sibling harness so this broad harness
# stays below the touched-file line cap.
# ============================================================================
printf '\nT6c/T10: recovery split harness\n'
set +e
sh "$TEST_DIR/install_sh_recovery_test.sh"
recovery_rc=$?
set -e
assert_eq "T6c/T10.1 split harness exit code 0" "0" "$recovery_rc"

# ============================================================================
# T7: --login-base-url is parsed + forwarded to `daemon login` (#1748 P0 web
# command injects it). Pre-plant recorder so binary-present gate skips download.
# ============================================================================
printf '\nT7: --login-base-url forwarded to daemon login\n'
make_sandbox; make_uname_fake
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"
set +e
INSTALL_OUT="$(HOME="$SANDBOX/home" PATH="$(sandbox_path)" FAKE_DAEMON_FAIL_CMD="" \
    GUILDOS_DAEMON_RELEASE_TAG="v0.61.40" \
    sh "$INSTALL_SH" --login-base-url "https://app.example.test" 2>&1)"
INSTALL_RC=$?
set -e
assert_eq "T7.1 exit code 0" "0" "$INSTALL_RC"
assert_eq "T7.2 chain order is exactly login then setup" "login setup" \
    "$(awk '{print $1}' "$SANDBOX/daemon_calls" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "T7.3 forwards --login-base-url flag to login" \
    "login --login-base-url" "$(daemon_first_call)"
assert_contains "T7.4 forwards the injected origin value" "https://app.example.test" "$(daemon_first_call)"
teardown_sandbox

# T8: unknown argument → exit 2 (a mistaken `--token ...` paste fails loud).
printf '\nT8: unknown argument exits 2\n'
make_sandbox
set +e
INSTALL_OUT="$(HOME="$SANDBOX/home" PATH="$(sandbox_path)" \
    sh "$INSTALL_SH" --token sekret 2>&1)"
INSTALL_RC=$?
set -e
assert_eq "T8.1 exit code 2 on unknown argument" "2" "$INSTALL_RC"
assert_contains "T8.2 prints unknown-argument error" "unknown argument" "$INSTALL_OUT"
assert_file_absent "T8.3 nothing chained when args rejected" "$SANDBOX/daemon_calls"
teardown_sandbox

# ============================================================================
# T9: login failure (timeout / closed browser) → reachable re-run hint + exit 5.
# Regression for the set -e masking bug: a non-zero `daemon login` must NOT
# swallow the recovery guidance, and setup must NOT chain after a failed login.
# ============================================================================
printf '\nT9: login failure prints re-run hint + exit 5\n'
make_sandbox; make_uname_fake
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40"
FAKE_DAEMON_FAIL_CMD="login"; run_install_sh; FAKE_DAEMON_FAIL_CMD=""
GUILDOS_DAEMON_RELEASE_TAG=""
assert_eq "T9.1 exit code 5 on login failure" "5" "$INSTALL_RC"
assert_contains "T9.2 prints reachable re-run-login hint (absolute path)" \
    '$HOME/.guildos/daemon/daemon login' "$INSTALL_OUT"
assert_not_contains "T9.3 setup NOT chained after a failed login" "setup" "$(daemon_calls)"
teardown_sandbox

# ============================================================================
# T11: login failure WITH --login-base-url → re-run hint PRESERVES the origin
# (Challenger ② C1): a non-default environment must not be sent back to the prod
# default on retry. Asserts the exact retry command (which only appears in the
# hint, not the chain message) carries the same origin.
# ============================================================================
printf '\nT11: login-failure re-run hint preserves --login-base-url\n'
make_sandbox; make_uname_fake
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"
set +e
INSTALL_OUT="$(HOME="$SANDBOX/home" PATH="$(sandbox_path)" FAKE_DAEMON_FAIL_CMD="login" \
    GUILDOS_DAEMON_RELEASE_TAG="v0.61.40" \
    sh "$INSTALL_SH" --login-base-url "https://app.example.test" 2>&1)"
INSTALL_RC=$?
set -e
assert_eq "T11.1 exit code 5 on login failure" "5" "$INSTALL_RC"
assert_contains "T11.2 re-run hint is the exact retry command WITH the origin" \
    '$HOME/.guildos/daemon/daemon login --login-base-url https://app.example.test' "$INSTALL_OUT"
assert_not_contains "T11.3 setup NOT chained after a failed login" "setup" "$(daemon_calls)"
teardown_sandbox

# ============================================================================
# T12: empty --login-base-url (both forms) fails loud — an explicit-but-empty
# flag must NOT be silently swallowed into the default origin (Gemini MEDIUM,
# same silent-misdirection class as C1).
# ============================================================================
printf '\nT12: empty --login-base-url exits 2\n'
make_sandbox
set +e
OUT_SPACE="$(HOME="$SANDBOX/home" PATH="$(sandbox_path)" sh "$INSTALL_SH" --login-base-url "" 2>&1)"
rc_space=$?
OUT_EQ="$(HOME="$SANDBOX/home" PATH="$(sandbox_path)" sh "$INSTALL_SH" --login-base-url= 2>&1)"
rc_eq=$?
set -e
assert_eq "T12.1 space-form empty value → exit 2" "2" "$rc_space"
assert_eq "T12.2 equals-form empty value → exit 2" "2" "$rc_eq"
assert_contains "T12.3 space-form prints non-empty-value error" "non-empty value" "$OUT_SPACE"
assert_contains "T12.4 equals-form prints non-empty-value error" "non-empty value" "$OUT_EQ"
assert_file_absent "T12.5 nothing chained on empty value" "$SANDBOX/daemon_calls"
teardown_sandbox

# ============================================================================
# T13: Windows installer static guards. These scripts cannot execute on this
# Linux CI host, but the static failure classes are contractual.
# ============================================================================
printf '\nT13: Windows installer static guards\n'
PS1_BODY="$(cat scripts/guildos-daemon-install.ps1)"
BAT_BODY="$(cat scripts/guildos-daemon-install.bat)"
assert_contains "T13.1 PS1 enables TLS 1.2" "Tls12" "$PS1_BODY"
assert_not_contains "T13.2 PS1 avoids RuntimeInformation for PowerShell 5.1" "RuntimeInformation" "$PS1_BODY"
assert_not_contains "T13.3 PS1 does not use Write-Error before explicit exits" "Write-Error" "$PS1_BODY"
assert_contains "T13.4 PS1 downloads are terminating" "-ErrorAction Stop" "$PS1_BODY"
assert_contains "T13.5 PS1 accepts kebab-case login-base-url alias" "Alias('login-base-url')" "$PS1_BODY"
assert_contains "T13.6 PS1 chains setup after login" "setup --daemon-binary" "$PS1_BODY"
assert_contains "T13.7 PS1 reports Windows service status command" "sc.exe query GuildOSDaemon" "$PS1_BODY"
assert_contains "T13.8 PS1 setup failure reports machine-added partial success" "The machine has been added" "$PS1_BODY"
assert_contains "T13.9 BAT transparently forwards installer arguments to PS1" "%*" "$BAT_BODY"
assert_contains "T13.10 BAT bootstrap enables TLS 1.2" "Tls12" "$BAT_BODY"
assert_contains "T13.11 BAT bootstrap download is terminating" "-ErrorAction Stop" "$BAT_BODY"
assert_contains "T13.12 PS1 checks Administrator before download/login/setup" "Test-IsAdministrator" "$PS1_BODY"
assert_contains "T13.13 PS1 admin failure gives clear instruction" "Administrator PowerShell" "$PS1_BODY"
assert_contains "T13.14 PS1 resolves latest tag through GitHub API" "api.github.com/repos/AivoGen/guildos-release/releases/latest" "$PS1_BODY"
assert_contains "T13.15 PS1 uses numeric semver comparison" "Test-SemverGreaterOrEqual" "$PS1_BODY"
assert_contains "T13.16 PS1 probes setup capability before reuse" "setup --help" "$PS1_BODY"
assert_contains "T13.17 BAT checks elevation with robust errorlevel" "if errorlevel 1" "$BAT_BODY"
assert_contains "T13.18 BAT admin failure gives clear instruction" "Administrator PowerShell or Command Prompt" "$BAT_BODY"
assert_not_contains "T13.19 PS1 latest resolution avoids BaseResponse" "BaseResponse" "$PS1_BODY"
assert_contains "T13.20 PS1 setup failure preserves exit 0 after login success" "exit 0" "$PS1_BODY"
assert_contains "T13.21 PS1 setup failure offers callable setup retry" '& "$daemonBin" setup --daemon-binary "$daemonBin"' "$PS1_BODY"
assert_contains "T13.22 PS1 setup failure offers callable foreground run fallback" '& "$daemonBin" run' "$PS1_BODY"
assert_not_contains "T13.23 PS1 setup failure no longer exits 6" "Setup did not complete. Re-run from an elevated terminal" "$PS1_BODY"

# ============================================================================
# Summary
# ============================================================================
printf '\n----\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
