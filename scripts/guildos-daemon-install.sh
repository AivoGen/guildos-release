#!/bin/sh
# guildos-daemon-install.sh — POSIX shell installer for GuildOS daemon
#
# task #1344 PR8 (Architect dispatch msg=3b64e576 + scope ruling msg=03ae05ce):
# download-only wrapper for the new 3-stage daemon lifecycle (design v2.5 §11.3).
# This script replaces the legacy `daemon run --install-only` bootstrap path
# (retired by PR7 [ref:1d8c1afd] cli/run.rs simplification).
#
# Phase 1 backbone (#1344) split lifecycle into three operator-driven stages:
#
#   Stage 1 — `daemon install`  (this script chains to it)
#       Writes the skeleton config at `~/.guildos/daemon/config.toml`
#       (no creds yet — just paths + runtime defaults). Idempotent.
#
#   Stage 2 — `daemon login`    (operator runs themselves)
#       Pairs the machine to a Core account via /init+/complete+/poll.
#       Writes the daemon_token plaintext into `[core]` block of config.
#
#   Stage 3 — `daemon setup`    (operator runs themselves)
#       Hashes daemon_token, calls /api/setup/finalize, installs the
#       systemd user-unit, runs `systemctl --user enable --now`.
#
# This script is intentionally PARAMETERLESS (per Hoping dm:a9e6bb9e +
# dm:e34cda7c, re-confirmed Architect msg=03ae05ce Q1):
#   - Token + core URL do NOT transit through shell argv (security win;
#     legacy `--token <api_token>` was visible in process listings).
#   - One-command paste: `curl -fL <url> | sh`
#   - Post-install guidance points operator at `daemon login` for pairing.
#
# Env overrides (NON-DEFAULT test path; production uses `latest`):
#   GUILDOS_DAEMON_RELEASE_TAG  — pin a specific release tag (default `latest`).
#                                 e.g. `GUILDOS_DAEMON_RELEASE_TAG=v0.60.0 sh install.sh`

set -eu

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
# parameterless contract from Q1.
RELEASE_TAG="${GUILDOS_DAEMON_RELEASE_TAG:-latest}"
if [ "$RELEASE_TAG" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/AivoGen/guildos-release/releases/latest/download/${ASSET}"
else
    DOWNLOAD_URL="https://github.com/AivoGen/guildos-release/releases/download/${RELEASE_TAG}/${ASSET}"
fi

# ---- binary-presence idempotency gate (Architect Q4 ruling msg=03ae05ce) ----
# Skip download iff the canonical binary is already present. We do NOT inspect
# systemd / PID / pgrep here — the legacy 3-way "already running" check moved
# to `daemon install` (config idempotency) + `daemon setup` (systemd lifecycle).
# Rationale: install.sh has no service-manager concerns in the new model.
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

# ---- chain into Stage 1 (`daemon install`) ----
# Architect Q3 ruling msg=03ae05ce: FOREGROUND call (not exec, not print-only).
# Foreground lets install.sh remain the parent + print final guidance after
# Stage 1 completes. `daemon install` writes the skeleton config + runtime
# defaults; it does NOT pair or start the daemon — those are Stages 2 + 3.
printf 'Chaining to Stage 1 (`daemon install`) ...\n'
"$DAEMON_BIN" install

# ---- post-install guidance ----
# UI_UX msg=04058cdc copy guidance + UI_UX r1 msg=9b6aed4b: 3-step flow
# (install → login → setup) with the EXACT runnable binary path so a
# clean-host operator can copy-paste each line without translation.
#
# r1 (Architect amended ruling msg=fafae0c7 closing QA Gate3 BLOCK
# msg=8008078d + Challenger Gate2 BLOCK msg=97689eb5):
#   - Use absolute binary path `$HOME/.guildos/daemon/daemon` (install.sh
#     does NOT touch PATH, so a bare `guildos-daemon` command does not
#     resolve on a fresh host).
#   - Login: bare `daemon login` per parameterless spirit (skeleton's
#     `[machine].login_base_url = "https://guildos.ai"` is the default;
#     operator runs `daemon login --help` to discover the override flag
#     `--login-base-url`, which Architect ruled is NOT shown in primary
#     guidance to keep the happy path single-line).
#   - Setup: REQUIRES `--company-id <uuid>` per cli/commands.rs:156
#     (`#[arg(long)] company_id: Uuid` — no default; the auto-pick
#     follow-up is queued post-Phase-1 per PR6 Q ruling).
cat <<'NEXT_STEPS'

guildos-daemon installed. Next steps:

  1. Pair this machine to your Core account:
       $HOME/.guildos/daemon/daemon login

  2. Finalize the daemon registration + install the systemd user unit
     (replace <your-company-id> with the Company UUID from your Core
     account; auto-pick lands in a follow-up release):
       $HOME/.guildos/daemon/daemon setup --company-id <your-company-id>

  3. The daemon will start automatically once Stage 3 completes. To check:
       systemctl --user status guildos-daemon

NEXT_STEPS
