#!/bin/sh
# guildos-daemon-install.sh — POSIX shell installer for GuildOS daemon
#
# task #1748 P1 (Architect dispatch msg=205702cc, scope A msg=5c7e9afb): migrate
# the install chain to the login→setup lifecycle so onboarding is ONE command.
# The former Stage-1 `daemon install` subcommand was folded into `daemon login`
# (#1746 — login now self-bootstraps the machine identity), so this script
# downloads the binary then chains login → setup in the foreground. The old chain
# target (`daemon install`) no longer exists on the daemon and would error out.
#
# Lifecycle (design daemon-onboarding-login-setup.md §2 / §4.3 / §5):
#
#   download (this script)
#       Fetches the daemon binary into `~/.guildos/daemon/daemon`. Idempotent.
#
#   Stage 1 — `daemon login [--login-base-url <url>]`  (this script chains to it)
#       Self-bootstraps the machine identity, prints the browser approval URL
#       (`<base>/pair?m=&n=`), and polls `/api/login/poll` until the operator
#       approves + picks a company in the browser. Persists the paired `[core]`
#       credentials.
#
#   Stage 2 — `daemon setup`  (this script chains to it — NO `--company-id`)
#       Calls `/api/setup/finalize` (which binds the company chosen at approval
#       time, #1748 P1 A) + installs/starts the platform service where
#       supported. macOS finalizes the long-term daemon credentials and prints an
#       explicit foreground fallback; LaunchAgent management is intentionally
#       not implied yet. The operator never types a company UUID.
#
# Argv contract (security): NO secrets in argv. The ONLY accepted flag is the
# OPTIONAL, non-secret `--login-base-url <url>` — injected by the web "Add
# machine" command (#1748 P0) so the daemon points its pairing flow at the same
# origin the operator is signed into. Token + core URL never transit argv (the
# legacy `--token <api_token>` was visible in process listings). When the flag
# is omitted, `daemon login` falls back to the skeleton config default
# (`[machine].login_base_url = "https://guildos.ai"`).
#
# Env overrides (NON-DEFAULT test path; production uses `latest`):
#   GUILDOS_DAEMON_RELEASE_TAG  — pin a specific release tag (default `latest`).
#                                 e.g. `GUILDOS_DAEMON_RELEASE_TAG=v0.60.0 sh install.sh`

set -eu

# ---- argv parse (only the optional, non-secret --login-base-url) ----
# Accepting one public URL flag does NOT reintroduce the secret-in-argv problem
# the parameterless contract guarded against — the login base is a public
# origin, not a credential.
LOGIN_BASE_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --login-base-url)
            shift
            # Require a present AND non-empty value: an explicit but empty
            # `--login-base-url ""` must NOT be silently swallowed into the
            # default origin (same silent-misdirection class as the retry hint).
            { [ $# -gt 0 ] && [ -n "$1" ]; } || {
                printf 'error: --login-base-url requires a non-empty value\n' >&2
                exit 2
            }
            LOGIN_BASE_URL="$1"
            ;;
        --login-base-url=*)
            LOGIN_BASE_URL="${1#--login-base-url=}"
            [ -n "$LOGIN_BASE_URL" ] || {
                printf 'error: --login-base-url requires a non-empty value\n' >&2
                exit 2
            }
            ;;
        *)
            printf 'error: unknown argument: %s (only --login-base-url is accepted)\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

# ---- platform detect ----
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
RUN_SETUP=0
SETUP_MODE=systemd
case "${UNAME_S}-${UNAME_M}" in
    Linux-x86_64)
        ASSET="guildos-daemon-linux-x86_64"
        RUN_SETUP=1
        SETUP_MODE=systemd
        ;;
    Darwin-arm64|Darwin-aarch64)
        ASSET="guildos-daemon-darwin-arm64"
        RUN_SETUP=1
        SETUP_MODE=macos-foreground
        ;;
    Darwin-x86_64)
        ASSET="guildos-daemon-darwin-x86_64"
        RUN_SETUP=1
        SETUP_MODE=macos-foreground
        ;;
    *)
        printf 'unsupported platform: %s-%s (supports Linux x86_64, macOS arm64, macOS x86_64)\n' \
            "$UNAME_S" "$UNAME_M" >&2
        exit 3
        ;;
esac

# ---- release tag selection (latest by default; env override for test) ----
# Architect Q2 ruling msg=03ae05ce: latest default, GUILDOS_DAEMON_RELEASE_TAG
# env override for test/dogfood. Don't fold pin into argv — violates the
# no-secrets-in-argv contract.
RELEASE_TAG="${GUILDOS_DAEMON_RELEASE_TAG:-latest}"
if [ "$RELEASE_TAG" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/AivoGen/guildos-release/releases/latest/download/${ASSET}"
else
    DOWNLOAD_URL="https://github.com/AivoGen/guildos-release/releases/download/${RELEASE_TAG}/${ASSET}"
fi

# ---- canonical install paths (match design v2.5 §4.6.4) ----
DAEMON_DIR="$HOME/.guildos/daemon"
DAEMON_BIN="$DAEMON_DIR/daemon"

print_login_command() {
    if [ -n "$LOGIN_BASE_URL" ]; then
        printf '       $HOME/.guildos/daemon/daemon login --login-base-url %s\n' "$LOGIN_BASE_URL"
    else
        printf '       $HOME/.guildos/daemon/daemon login\n'
    fi
}

print_manual_login_command() {
    if [ -n "$LOGIN_BASE_URL" ]; then
        printf '       "%s" login --login-base-url %s\n' "$DAEMON_BIN" "$LOGIN_BASE_URL"
    else
        printf '       "%s" login\n' "$DAEMON_BIN"
    fi
}

open_url() {
    url="$1"
    case "$UNAME_S" in
        Darwin) opener="open" ;;
        Linux) opener="xdg-open" ;;
        *) return 1 ;;
    esac
    command -v "$opener" >/dev/null 2>&1 || return 1
    if [ "$opener" = "xdg-open" ] && command -v timeout >/dev/null 2>&1; then
        timeout 5s "$opener" "$url" >/dev/null 2>&1
        return $?
    fi
    "$opener" "$url" >/dev/null 2>&1
}

manual_helper_url() {
    reason="$1"
    helper_base="${LOGIN_BASE_URL:-https://guildos.ai}"
    helper_base="${helper_base%/}"
    printf '%s/daemon-install-help?reason=%s&asset=%s\n' "$helper_base" "$reason" "$ASSET"
}

print_helper_page_hint() {
    reason="$1"
    label="$2"
    helper_url="$(manual_helper_url "$reason")"
    if open_url "$helper_url"; then
        printf 'Opened %s helper page in your browser:\n       %s\n\n' "$label" "$helper_url"
    else
        printf 'Open this %s helper page in your browser:\n       %s\n\n' "$label" "$helper_url"
    fi
}

print_manual_download_instructions() {
    print_helper_page_hint "missing-curl" "manual install"
    printf '%s\n' "curl was not found, so the installer cannot download the daemon automatically.

Manual install path for this machine:
       Asset: $ASSET
       Download: $DOWNLOAD_URL

After downloading the asset, place it at:
       $DAEMON_BIN

Then run:
       mkdir -p \"$DAEMON_DIR\"
       chmod 700 \"$DAEMON_DIR\"
       mv \"/path/to/$ASSET\" \"$DAEMON_BIN\"
       chmod +x \"$DAEMON_BIN\""
    print_manual_login_command
    printf '       "%s" setup\n\n' "$DAEMON_BIN"
    printf '%s\n' 'If service setup is not available yet, keep the machine online with:'
    printf '       "%s" run\n' "$DAEMON_BIN"

}

if ! command -v curl >/dev/null 2>&1; then
    print_manual_download_instructions >&2
    exit 4
fi

mkdir -p "$DAEMON_DIR"
chmod 700 "$DAEMON_DIR"

# ---- binary reuse gate -------------------------------------------------------
parse_semver() {
    printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*$/\1 \2 \3/p'
}

semver_ge() {
    have_parts=$(parse_semver "$1")
    want_parts=$(parse_semver "$2")
    [ -n "$have_parts" ] && [ -n "$want_parts" ] || return 1
    set -- $have_parts $want_parts
    have_major=$1; have_minor=$2; have_patch=$3
    want_major=$4; want_minor=$5; want_patch=$6
    [ "$have_major" -gt "$want_major" ] && return 0
    [ "$have_major" -lt "$want_major" ] && return 1
    [ "$have_minor" -gt "$want_minor" ] && return 0
    [ "$have_minor" -lt "$want_minor" ] && return 1
    [ "$have_patch" -ge "$want_patch" ]
}

resolve_latest_release_tag() {
    latest_url="https://github.com/AivoGen/guildos-release/releases/latest"
    effective_url=$(curl -fsIL -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null || true)
    printf '%s\n' "$effective_url" | sed -n 's#.*/releases/tag/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[^/?#]*\).*#\1#p'
}

if [ "$RELEASE_TAG" = "latest" ]; then
    TARGET_VERSION="$(resolve_latest_release_tag)"
else
    TARGET_VERSION="$RELEASE_TAG"
fi

daemon_reusable() {
    [ -x "$DAEMON_BIN" ] || return 1
    [ -n "$TARGET_VERSION" ] || return 1
    local_version=$("$DAEMON_BIN" --version 2>/dev/null || true)
    semver_ge "$local_version" "$TARGET_VERSION" || return 1
    "$DAEMON_BIN" setup --help >/dev/null 2>&1 || return 1
    return 0
}

if daemon_reusable; then
    printf 'Daemon binary at %s is current and supports setup — skipping download.\n' "$DAEMON_BIN"
else
    if [ -e "$DAEMON_BIN" ]; then
        printf 'Daemon binary at %s is old, unparseable, lacks setup, or target version could not be resolved — replacing it.\n' "$DAEMON_BIN"
    fi
    TMP_BIN=$(mktemp "$DAEMON_DIR/daemon.tmp.XXXXXXXX")
    trap 'rm -f "$TMP_BIN"' EXIT INT TERM HUP

    printf 'Downloading %s from %s ...\n' "$ASSET" "$DOWNLOAD_URL"
    if ! curl -fL --proto '=https' --tlsv1.2 -o "$TMP_BIN" "$DOWNLOAD_URL"; then
        printf 'download failed from %s\n' "$DOWNLOAD_URL" >&2
        exit 4
    fi
    chmod +x "$TMP_BIN"
    # atomic install: rename inside same fs is atomic on POSIX (fd26d3b lock-in)
    mv "$TMP_BIN" "$DAEMON_BIN"
    trap - EXIT INT TERM HUP
    printf 'Installed daemon to %s\n' "$DAEMON_BIN"
fi

# ---- chain Stage 1 (`daemon login`) then Stage 2 (`daemon setup`) ----
# The former `daemon install` (skeleton-config) step was folded into
# `daemon login` (#1746): login self-bootstraps the identity, then pairs. We run
# login + setup in the FOREGROUND (Architect Q3 ruling msg=03ae05ce) so the
# operator completes onboarding in ONE command — pair in the browser, then setup
# finalizes credentials. Linux setup also installs the systemd unit; macOS setup
# currently finalizes and then prints an explicit foreground fallback.
#
# Each stage runs under `set +e` + an explicit exit-code check: under `set -e` a
# non-zero stage would abort on that line BEFORE its recovery hint could print,
# leaving the operator without retry guidance on exactly the failing path.
set +e
if [ -n "$LOGIN_BASE_URL" ]; then
    printf 'Chaining to Stage 1 (`daemon login --login-base-url %s`) ...\n' "$LOGIN_BASE_URL"
    "$DAEMON_BIN" login --login-base-url "$LOGIN_BASE_URL"
else
    printf 'Chaining to Stage 1 (`daemon login`) ...\n'
    "$DAEMON_BIN" login
fi
login_rc=$?
set -e
if [ "$login_rc" -ne 0 ]; then
    # Print the EXACT retry command, preserving the operator's --login-base-url
    # so a non-default environment (testserver / self-hosted / staging) is NOT
    # sent back to the prod default on re-run. printf keeps `$HOME` literal so
    # the operator's shell expands it on paste.
    printf '\nPairing did not complete. If it timed out or the browser was closed, re-run:\n' >&2
    if [ -n "$LOGIN_BASE_URL" ]; then
        printf '       $HOME/.guildos/daemon/daemon login --login-base-url %s\n' "$LOGIN_BASE_URL" >&2
    else
        printf '       $HOME/.guildos/daemon/daemon login\n' >&2
    fi
    exit 5
fi

if [ "$RUN_SETUP" -ne 1 ]; then
    cat <<'NEXT_STEPS'

guildos-daemon installed and paired.

Run daemon setup before starting the daemon:
       $HOME/.guildos/daemon/daemon setup

NEXT_STEPS
    exit 0
fi

# Stage 2: `daemon setup` WITHOUT `--company-id`. #1748 P1 (A): the company is
# chosen in the browser at approval time and finalize binds it from the pairing
# row, so the operator never types a company UUID. (Requires the daemon build
# where `setup` no longer client-resolves the company —
# task/1748-p1-daemon-setup-skip-resolve.)
set +e
printf 'Chaining to Stage 2 (`daemon setup`) ...\n'
"$DAEMON_BIN" setup
setup_rc=$?
set -e
if [ "$setup_rc" -ne 0 ]; then
    if [ "$SETUP_MODE" = "systemd" ]; then
        print_helper_page_hint "setup-service" "setup recovery" >&2
        cat <<'SETUP_FAIL_HEAD'

guildos-daemon installed and paired. The machine has been added, but service setup did not complete.

Setup failure reason:
SETUP_FAIL_HEAD
        printf '       daemon setup exited with code %s. See the setup output above for details.\n\n' "$setup_rc"
        cat <<'SETUP_FAIL_TAIL'
Recovery options:
       $HOME/.guildos/daemon/daemon setup
       $HOME/.guildos/daemon/daemon run

If setup reported permission or service-manager errors, retry setup from a shell with access to the user systemd session, then check the service:
       systemctl --user status guildos-daemon
SETUP_FAIL_TAIL
    else
        print_helper_page_hint "setup-service" "setup recovery" >&2
        cat <<'SETUP_FAIL_HEAD'

guildos-daemon installed and paired. The machine has been added, but setup did not complete.

Setup failure reason:
SETUP_FAIL_HEAD
        printf '       daemon setup exited with code %s. See the setup output above for details.\n\n' "$setup_rc"
        cat <<'SETUP_FAIL_TAIL'
Recovery options:
       $HOME/.guildos/daemon/daemon setup
       $HOME/.guildos/daemon/daemon run
SETUP_FAIL_TAIL
    fi
    exit 0
fi

if [ "$SETUP_MODE" = "macos-foreground" ]; then
    cat <<'NEXT_STEPS'

✓ guildos-daemon installed, paired, and finalized.

macOS service auto-start is not available yet. Start it in this terminal with:
       $HOME/.guildos/daemon/daemon run

Keep that process running to maintain the machine connection.

NEXT_STEPS
    exit 0
fi

cat <<'NEXT_STEPS'

✓ guildos-daemon installed, paired, and started.

Check the service any time with:
       systemctl --user status guildos-daemon

NEXT_STEPS
