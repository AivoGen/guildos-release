# guildos-release

PUBLIC release repository for the GuildOS daemon binary + manifest.
Companion to the PRIVATE `AivoGen/guildos` repo (core + UI source).

## Contents

| Path | Purpose |
|---|---|
| `releases/` | Per-version directories with daemon binary archives + per-release manifest snapshots |
| `manifest/` | Rolling manifest pointing at the current "stable" daemon release (consumed by daemon self-update poller) |
| `scripts/guildos-daemon-install.sh` | POSIX shell installer for the daemon (see "Install script" below) |

## Install script (`scripts/guildos-daemon-install.sh`)

Canonical location for the daemon installer (#1323; previously lived
under `AivoGen/guildos:scripts/install/guildos-daemon-install.sh` and
shipped as a release artifact). Decoupled so the installer's
lifecycle is independent of GuildOS core/UI release cadence — it's a
shell script, not a versioned binary.

The PRIVATE-side `tools/deploy.sh::cut_public_release` fetches this
script at a PINNED commit SHA via raw.githubusercontent.com (NOT
floating `main`) when building each PUBLIC release on this repo. The
pin lives in `AivoGen/guildos:tools/deploy.sh`; bumping it is an
explicit cross-repo step rather than a "main moved" race.

End-user install flow (from the GuildOS UI's "Add Machine" modal):

```sh
curl -fL https://github.com/AivoGen/guildos-release/releases/latest/download/guildos-daemon-install.sh \
  | bash -s -- --token <api_token> --core-url <core_ws_url>
```

The `releases/latest/download/` URL keeps end-users on the version
the most recent PUBLIC release bundled in (per-release frozen copy),
so an in-tree edit doesn't change what an in-production machine
installs until the next release cut.
