#!/bin/sh
# Focused installer reuse/latest harness. Invoked by install_sh_test.sh and
# runnable directly: sh tests/install_sh_reuse_test.sh.

set -eu

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/guildos-daemon-install.sh"

FAIL_COUNT=0
PASS_COUNT=0
SANDBOX=""
ORIG_PATH="$PATH"
INSTALL_RC=0
INSTALL_OUT=""

make_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/install-sh-reuse-test.XXXXXXXX")"
    mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/curl_log"
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

make_curl_planter() {
    cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
for arg in "\$@"; do
    if [ "\$arg" = "-w" ]; then
        printf 'https://github.com/AivoGen/guildos-release/releases/tag/v0.61.40'
        exit 0
    fi
done
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
exit 0
DAEMON_PAYLOAD
fi
exit 0
CURL_EOF
    chmod +x "$SANDBOX/bin/curl"
}

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
        GUILDOS_DAEMON_RELEASE_TAG="${GUILDOS_DAEMON_RELEASE_TAG:-}" \
        sh "$INSTALL_SH" 2>&1
    )"
    INSTALL_RC=$?
    set -e
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

assert_file_absent() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL %s\n    path should not exist: %s\n' "$label" "$path" >&2
    else
        PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$label"
    fi
}

printf '\nT3a: stale binary is replaced before login/setup\n'
make_sandbox; make_uname_fake; make_curl_planter
plant_fake_daemon "$SANDBOX/home/.guildos/daemon" "0.60.0" "yes"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40" run_install_sh
assert_eq "T3a.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T3a.2 curl invoked to replace stale binary" \
    "releases/download/v0.61.40/guildos-daemon-linux-x86_64" "$(cat "$SANDBOX/curl_log/url")"
assert_eq "T3a.3 chain order is exactly login then setup" "login setup" "$(chain_order)"
assert_contains "T3a.4 prints replacement message" "replacing it" "$INSTALL_OUT"
teardown_sandbox

printf '\nT3b: current binary with setup support is reused\n'
make_sandbox; make_uname_fake
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
touch "$SANDBOX/curl_log/INVOKED"
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
plant_fake_daemon "$SANDBOX/home/.guildos/daemon" "0.61.40" "yes"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40" run_install_sh
assert_eq "T3b.1 exit code 0" "0" "$INSTALL_RC"
assert_file_absent "T3b.2 curl NOT invoked when version+setup are current" "$SANDBOX/curl_log/INVOKED"
assert_eq "T3b.3 chain order is exactly login then setup" "login setup" "$(chain_order)"
assert_contains "T3b.4 prints skip message" "skipping download" "$INSTALL_OUT"
teardown_sandbox

printf '\nT3c: current binary without setup is replaced\n'
make_sandbox; make_uname_fake; make_curl_planter
plant_fake_daemon "$SANDBOX/home/.guildos/daemon" "0.61.40" "no"
GUILDOS_DAEMON_RELEASE_TAG="v0.61.40" run_install_sh
assert_eq "T3c.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T3c.2 curl invoked when setup subcommand is absent" \
    "releases/download/v0.61.40/guildos-daemon-linux-x86_64" "$(cat "$SANDBOX/curl_log/url")"
teardown_sandbox

printf '\nT3d: semver compare is numeric\n'
make_sandbox; make_uname_fake
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
touch "$SANDBOX/curl_log/INVOKED"
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
plant_fake_daemon "$SANDBOX/home/.guildos/daemon" "0.100.0" "yes"
GUILDOS_DAEMON_RELEASE_TAG="v0.99.0" run_install_sh
assert_eq "T3d.1 exit code 0" "0" "$INSTALL_RC"
assert_file_absent "T3d.2 curl NOT invoked for numerically newer binary" "$SANDBOX/curl_log/INVOKED"
assert_eq "T3d.3 chain order is exactly login then setup" "login setup" "$(chain_order)"
teardown_sandbox

printf '\nT3e: unresolved latest tag downloads instead of skipping\n'
make_sandbox; make_uname_fake
cat >"$SANDBOX/bin/curl" <<CURL_EOF
#!/bin/sh
for arg in "\$@"; do
    if [ "\$arg" = "-w" ]; then
        exit 0
    fi
done
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
exit 0
DAEMON_PAYLOAD
fi
exit 0
CURL_EOF
chmod +x "$SANDBOX/bin/curl"
plant_fake_daemon "$SANDBOX/home/.guildos/daemon" "0.61.40" "yes"
unset GUILDOS_DAEMON_RELEASE_TAG
run_install_sh
assert_eq "T3e.1 exit code 0" "0" "$INSTALL_RC"
assert_contains "T3e.2 latest URL downloaded when target version unresolved" \
    "releases/latest/download/guildos-daemon-linux-x86_64" "$(cat "$SANDBOX/curl_log/url")"
teardown_sandbox

printf '\n----\n'
printf 'REUSE PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
