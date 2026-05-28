#!/bin/sh
# install_sh_test.sh — POSIX behavioral harness for
# `scripts/guildos-daemon-install.sh` (task #1344 PR8).
#
# Architect Q5 ruling msg=03ae05ce (a): guildos-release self-tests its one
# canonical script. shellcheck (b) is static-only — misses behavioral
# correctness (chain-to-install + no-service-manager + idempotency).
#
# Strategy: build a sandbox $HOME with HOME=, PATH= shimmed so `curl` and
# `uname` are replaced with deterministic fakes. The install.sh under test
# downloads via the fake curl (which writes a fake "binary" payload) then
# chains to a fake `daemon` binary that records its argv. Assertions then
# inspect the recorded calls + paths.
#
# Run:
#   sh tests/install_sh_test.sh
# Exits 0 on PASS, non-zero on first FAIL.

set -eu

# Locate the script-under-test relative to this test (works from any cwd).
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/guildos-daemon-install.sh"

if [ ! -f "$INSTALL_SH" ]; then
    printf 'FATAL: install.sh not found at %s\n' "$INSTALL_SH" >&2
    exit 99
fi

FAIL_COUNT=0
PASS_COUNT=0

# Per-test sandbox lifecycle:
#   make_sandbox <name>    -> creates SANDBOX dir, fake HOME, fake PATH bin dir
#   teardown_sandbox       -> rm -rf SANDBOX
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

# Fake `uname` (always reports Linux-x86_64 so platform gate passes).
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

# Fake `uname` for unsupported platform (forces exit 3 path).
make_uname_unsupported() {
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

# Fake `curl` that records argv + writes a tiny fake binary payload to the
# `-o <path>` target. Always succeeds unless FAKE_CURL_FAIL=1.
make_curl_fake() {
    cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
# record full argv (one per line) for later assertion
printf '%s\n' "\$@" > "$SANDBOX/curl_log/argv"
# pull out the -o target + the final URL (works for the canonical install.sh
# call shape: curl -fL --proto '=https' --tlsv1.2 -o <out> <url>)
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
if [ "\${FAKE_CURL_FAIL:-0}" = "1" ]; then
    printf 'fake-curl: simulated failure\n' >&2
    exit 22
fi
if [ -n "\$out_path" ]; then
    printf 'FAKE-DAEMON-BINARY-PAYLOAD\n' > "\$out_path"
fi
exit 0
CURL_EOF
    chmod +x "$SANDBOX/bin/curl"
}

# Fake `daemon` binary that records the subcommand+argv that install.sh
# chains to. Placed at the canonical install path so install.sh finds it
# after the download step (or treats it as already-present for the
# idempotency test).
plant_fake_daemon() {
    target_dir="$1"
    mkdir -p "$target_dir"
    cat >"$target_dir/daemon" <<DAEMON_EOF
#!/bin/sh
# Record what install.sh called us with — full argv, one per line.
printf '%s\n' "\$@" > "$SANDBOX/daemon_call_argv"
exit 0
DAEMON_EOF
    chmod +x "$target_dir/daemon"
}

# Replace the freshly-downloaded "binary" (a 1-line fake from curl) with the
# argv-recording fake AFTER install.sh moves it into place. We do this by
# pre-planting at the canonical path BEFORE running install.sh, so the
# binary-presence gate skips download and chains straight to install.
# Tests that exercise the download path use a wrapper script instead.

# Build a sandboxed PATH that finds our fakes first but still has /usr/bin
# essentials (sh, printf, mv, mkdir, chmod, mktemp, cat, etc.).
sandbox_path() {
    printf '%s:%s' "$SANDBOX/bin" "${ORIG_PATH:-$PATH}"
}

# Run install.sh under the sandbox. Returns its exit code in INSTALL_RC.
INSTALL_RC=0
INSTALL_OUT=""
run_install_sh() {
    # Capture both stdout + stderr for assertions.
    set +e
    INSTALL_OUT="$(
        HOME="$SANDBOX/home" \
        PATH="$(sandbox_path)" \
        sh "$INSTALL_SH" 2>&1
    )"
    INSTALL_RC=$?
    set -e
}

# Assertion helpers.
assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  PASS %s\n' "$label"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual" >&2
    fi
}
assert_contains() {
    label="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*)
            PASS_COUNT=$((PASS_COUNT + 1))
            printf '  PASS %s\n' "$label"
            ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            printf '  FAIL %s\n    needle: %s\n    not found in haystack\n' "$label" "$needle" >&2
            ;;
    esac
}
assert_not_contains() {
    label="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            printf '  FAIL %s\n    forbidden needle: %s\n    found in haystack\n' "$label" "$needle" >&2
            ;;
        *)
            PASS_COUNT=$((PASS_COUNT + 1))
            printf '  PASS %s\n' "$label"
            ;;
    esac
}
assert_file_exists() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  PASS %s\n' "$label"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    path missing: %s\n' "$label" "$path" >&2
    fi
}
assert_file_absent() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    path should not exist: %s\n' "$label" "$path" >&2
    else
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  PASS %s\n' "$label"
    fi
}

ORIG_PATH="$PATH"

# ============================================================================
# T1: happy path — fresh install, binary absent
#   - downloads from canonical `latest` URL
#   - atomic install via mktemp+mv (no .tmp.* leftover)
#   - chains to `daemon install` (foreground)
#   - prints 3-step next-step guidance (login → setup → systemctl status)
# ============================================================================
printf '\nT1: happy path (fresh install, latest tag)\n'
make_sandbox
make_uname_fake
make_curl_fake
# Replace the curl-written fake binary with an argv-recording one
# immediately after install.sh moves it into place. We achieve this by
# having curl write a SHIM that, when invoked, plants the recorder.
# Simpler: post-download, install.sh runs `$DAEMON_BIN install`; we make
# curl write a self-replacing shim.
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
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
    # Write an argv-recording fake daemon binary into the download target.
    cat >"\$out_path" <<'DAEMON_PAYLOAD'
#!/bin/sh
printf '%s\n' "\$@" > "$SANDBOX/daemon_call_argv"
exit 0
DAEMON_PAYLOAD
    # The heredoc above is single-quoted so \$@ stays literal but the
    # SANDBOX path needs to be the EXPANDED test-time path. Patch it in.
    sed -i "s#\\\$SANDBOX#$SANDBOX#g" "\$out_path"
fi
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"

run_install_sh

assert_eq "T1.1 exit code 0" "0" "$INSTALL_RC"
assert_file_exists "T1.2 daemon binary installed at canonical path" \
    "$SANDBOX/home/.guildos/daemon/daemon"
assert_contains "T1.3 curl URL points at latest" \
    "releases/latest/download/guildos-daemon-linux-x86_64" \
    "$(cat "$SANDBOX/curl_log/url")"
assert_contains "T1.4 chains to daemon install" \
    "install" "$(cat "$SANDBOX/daemon_call_argv" 2>/dev/null || echo NONE)"
# r1 strict assertions per Architect msg=fafae0c7 (closing dual-BLOCK
# from QA msg=8008078d + Challenger msg=97689eb5): printed guidance
# must be runnable-on-clean-host. Substring matches like "guildos-daemon
# login" false-greened r0 because they passed even when:
#   (a) the bare name `guildos-daemon` is not on PATH (binary lives
#       at `$HOME/.guildos/daemon/daemon`)
#   (b) the flag `--base-url` doesn't exist (real flag is
#       `--login-base-url`)
#   (c) `daemon setup` required `--company-id <uuid>` was omitted.
# These assertions lock the EXACT runnable forms.
assert_contains "T1.5a prints login with absolute binary path" \
    '$HOME/.guildos/daemon/daemon login' "$INSTALL_OUT"
assert_not_contains "T1.5b login does NOT print bare guildos-daemon (not on PATH)" \
    "guildos-daemon login" "$INSTALL_OUT"
assert_not_contains "T1.5c login does NOT print wrong --base-url flag" \
    "--base-url" "$INSTALL_OUT"
assert_contains "T1.6a prints setup with absolute path + required --company-id" \
    '$HOME/.guildos/daemon/daemon setup --company-id' "$INSTALL_OUT"
assert_not_contains "T1.6b setup does NOT print bare guildos-daemon (not on PATH)" \
    "guildos-daemon setup" "$INSTALL_OUT"
assert_contains "T1.7 prints systemctl --user status guidance" \
    "systemctl --user status" "$INSTALL_OUT"
# No leftover tmp file from atomic install
leftover_tmp=$(ls "$SANDBOX/home/.guildos/daemon/"daemon.tmp.* 2>/dev/null || true)
assert_eq "T1.8 no leftover daemon.tmp.* file" "" "$leftover_tmp"
teardown_sandbox

# ============================================================================
# T2: env override — GUILDOS_DAEMON_RELEASE_TAG=v0.60.0
#   - download URL uses pinned tag, not /latest/
# ============================================================================
printf '\nT2: env override GUILDOS_DAEMON_RELEASE_TAG\n'
make_sandbox
make_uname_fake
# Reuse the T1-style curl that plants the recorder.
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
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
printf '%s\n' "\$@" > "$SANDBOX/daemon_call_argv"
exit 0
DAEMON_PAYLOAD
    sed -i "s#\\\$SANDBOX#$SANDBOX#g" "\$out_path"
fi
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"

set +e
INSTALL_OUT="$(
    HOME="$SANDBOX/home" \
    PATH="$(sandbox_path)" \
    GUILDOS_DAEMON_RELEASE_TAG="v0.60.0" \
    sh "$INSTALL_SH" 2>&1
)"
INSTALL_RC=$?
set -e

assert_eq "T2.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T2.2 URL uses pinned v0.60.0 tag" \
    "releases/download/v0.60.0/guildos-daemon-linux-x86_64" \
    "$(cat "$SANDBOX/curl_log/url")"
assert_not_contains "T2.3 URL does NOT contain /latest/" \
    "/latest/" "$(cat "$SANDBOX/curl_log/url")"
teardown_sandbox

# ============================================================================
# T3: idempotency — binary already present
#   - skips curl entirely
#   - still chains to `daemon install` (idempotency owner)
# ============================================================================
printf '\nT3: idempotency (binary already present)\n'
make_sandbox
make_uname_fake
# Stub curl so we can detect that it was NOT called.
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
touch "$SANDBOX/curl_log/INVOKED"
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
# Pre-plant the daemon binary at the canonical path.
plant_fake_daemon "$SANDBOX/home/.guildos/daemon"

run_install_sh

assert_eq "T3.1 exit code 0" "0" "$INSTALL_RC"
assert_file_absent "T3.2 curl NOT invoked when binary present" \
    "$SANDBOX/curl_log/INVOKED"
assert_contains "T3.3 still chains to daemon install (idempotency)" \
    "install" "$(cat "$SANDBOX/daemon_call_argv" 2>/dev/null || echo NONE)"
assert_contains "T3.4 prints skip message" \
    "already present" "$INSTALL_OUT"
teardown_sandbox

# ============================================================================
# T4: no service-manager logic — shell must not INVOKE systemctl/systemd
#   - source-level static check on executable code only (skips comments
#     + heredoc body so historical/guidance mentions don't false-positive)
#   - previous script invoked systemctl/pgrep in `daemon_running()`; the
#     new download-only contract moves those out to `daemon install` +
#     `daemon setup`
#
# `code_only` strips comments (lines starting with optional whitespace + `#`)
# and the `cat <<'NEXT_STEPS' ... NEXT_STEPS` heredoc body — heredoc content
# is OUTPUT to the operator, not script execution.
# ============================================================================
printf '\nT4: no service-manager logic in shell\n'
code_only="$(awk '
    /^cat <<.NEXT_STEPS./ { in_heredoc = 1; next }
    in_heredoc && /^NEXT_STEPS$/ { in_heredoc = 0; next }
    in_heredoc { next }
    /^[[:space:]]*#/ { next }
    { print }
' "$INSTALL_SH")"
assert_not_contains "T4.1 no systemctl invocation in executable code" \
    "systemctl " "$code_only"
assert_not_contains "T4.2 no systemd-run invocation" \
    "systemd-run" "$code_only"
assert_not_contains "T4.3 no pgrep service-detection in executable code" \
    "pgrep " "$code_only"
assert_not_contains "T4.4 no daemon_running() gate" \
    "daemon_running" "$code_only"
assert_not_contains "T4.5 no --install-only flag in executable code (legacy bootstrap retired)" \
    "--install-only" "$code_only"
assert_not_contains "T4.6 no --token argv plumbing (parameterless contract)" \
    '"$TOKEN"' "$code_only"
assert_not_contains "T4.7 no --core-url argv plumbing (parameterless contract)" \
    '"$CORE_URL"' "$code_only"
assert_not_contains "T4.8 no daemon.pid PID-file check" \
    "daemon.pid" "$code_only"

# ============================================================================
# T5: download failure → non-zero exit, no chain to daemon install
# ============================================================================
printf '\nT5: download failure exits non-zero\n'
make_sandbox
make_uname_fake
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
printf 'fake-curl: simulated failure\n' >&2
exit 22
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
# DO NOT pre-plant daemon binary — we want install.sh to attempt download.

run_install_sh

# install.sh exits 4 on download failure
assert_eq "T5.1 exit code 4 on download failure" "4" "$INSTALL_RC"
assert_file_absent "T5.2 no daemon binary at canonical path" \
    "$SANDBOX/home/.guildos/daemon/daemon"
assert_file_absent "T5.3 daemon install NOT chained" \
    "$SANDBOX/daemon_call_argv"
assert_contains "T5.4 download failure error message" \
    "download failed" "$INSTALL_OUT"
# Atomic-install discipline: no leftover .tmp.* file even on failure
leftover_tmp=$(ls "$SANDBOX/home/.guildos/daemon/"daemon.tmp.* 2>/dev/null || true)
assert_eq "T5.5 no leftover daemon.tmp.* on download failure" "" "$leftover_tmp"
teardown_sandbox

# ============================================================================
# T6: unsupported platform → exit 3, no download attempted
# ============================================================================
printf '\nT6: unsupported platform (Darwin/arm64) exits 3\n'
make_sandbox
make_uname_unsupported
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
touch "$SANDBOX/curl_log/INVOKED"
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"

run_install_sh

assert_eq "T6.1 exit code 3 on unsupported platform" "3" "$INSTALL_RC"
assert_file_absent "T6.2 curl NOT invoked on platform reject" \
    "$SANDBOX/curl_log/INVOKED"
assert_contains "T6.3 platform error message" \
    "unsupported platform" "$INSTALL_OUT"
teardown_sandbox

# ============================================================================
# Summary
# ============================================================================
printf '\n----\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
