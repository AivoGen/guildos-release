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

The PRIVATE-side release pipeline fetches this script at a PINNED commit
SHA via raw.githubusercontent.com (NOT floating `main`) when building each
PUBLIC release on this repo. The pin lives in
`AivoGen/guildos:tools/deploy_install_sh_pin.sh`
(`GUILDOS_RELEASE_INSTALL_SH_PIN` + `_SHA256`); bumping it is an explicit
cross-repo step rather than a "main moved" race.

End-user install flow (from the GuildOS UI's "Add Machine" modal):

```sh
curl -fL https://github.com/AivoGen/guildos-release/releases/latest/download/guildos-daemon-install.sh \
  | bash -s -- --login-base-url <your_guildos_origin>
```

The command is **tokenless** and completes onboarding in **one step**
(#1748): no `--token` / `--core-url` ever transit shell argv. The script
downloads the daemon binary then chains `daemon login` → `daemon setup` in
the foreground — `login` prints a browser approval URL (`<base>/pair?m=&n=`)
and polls until you approve + pick a company in the browser; `setup` then
finalizes against the company you chose at approval (no company UUID to type)
and installs/starts the systemd unit, so the machine comes online and the
"Add Machine" modal advances to "✓ connected". The only accepted flag is the
optional, non-secret `--login-base-url <origin>` — the modal injects your
current origin so pairing targets the right environment; when omitted it
defaults to `https://guildos.ai`. If a stage doesn't complete (pairing
timeout, setup error) the script prints the exact re-run command and exits
non-zero.

The `releases/latest/download/` URL keeps end-users on the version
the most recent PUBLIC release bundled in (per-release frozen copy),
so an in-tree edit doesn't change what an in-production machine
installs until the next release cut.
