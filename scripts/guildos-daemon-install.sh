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
#       time, #1748 P1 A) + installs/starts the systemd user unit → machine
#       online. The operator never types a company UUID.
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
            [ $# -gt 0 ] || {
                printf 'error: --login-base-url requires a value\n' >&2
                exit 2
            }
            LOGIN_BASE_URL="$1"
            ;;
        --login-base-url=*)
            LOGIN_BASE_URL="${1#--login-base-url=}"
            ;;
        *)
            printf 'error: unknown argument: %s (only --login-base-url is accepted)\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

# ---- platform detect (Phase 1 = Linux x86_64 only per design §4.6.9) ----
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
case "${UNAME_S}-${UNAME_M}" in
    Linux-x86_64)
        ASSET="guildos-daemon-linux-x86_64"
        ;;
    *)
        printf 'unsupported platform: %s-%s (Phase 1 supports Linux x86_64 only)\n' \
            "$UNAME_S" "$UNAME_M" >&2
        exit 3
        ;;
esac

# ---- canonical install paths (match design v2.5 §4.6.4) ----
DAEMON_DIR="$HOME/.guildos/daemon"
DAEMON_BIN="$DAEMON_DIR/daemon"

mkdir -p "$DAEMON_DIR"
chmod 700 "$DAEMON_DIR"

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

# ---- binary-presence idempotency gate (Architect Q4 ruling msg=03ae05ce) ----
# Skip download iff the canonical binary is already present. We do NOT inspect
# systemd / PID / pgrep here — service-manager concerns live in `daemon setup`
# (systemd lifecycle); `daemon login` is idempotent on the machine identity.
if [ -e "$DAEMON_BIN" ]; then
    printf 'Daemon binary already present at %s — skipping download.\n' "$DAEMON_BIN"
else
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
# finalizes + installs the systemd unit and the machine comes online (so the web
# "Add machine" modal can auto-advance to "✓ connected").
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
    cat <<'LOGIN_FAIL'

Pairing did not complete. If it timed out or the browser was closed, re-run:
       $HOME/.guildos/daemon/daemon login
LOGIN_FAIL
    exit 5
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
    cat <<'SETUP_FAIL'

Setup did not complete. Re-run it, then check the service:
       $HOME/.guildos/daemon/daemon setup
       systemctl --user status guildos-daemon
SETUP_FAIL
    exit 6
fi

cat <<'NEXT_STEPS'

✓ guildos-daemon installed, paired, and started.

Check the service any time with:
       systemctl --user status guildos-daemon

NEXT_STEPS
