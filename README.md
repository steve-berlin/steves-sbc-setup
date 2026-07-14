# steves-sbc-setup

Idempotent provisioning scripts for headless servers and single-board computers.

Sibling of [steves-debian-setup](https://github.com/steve-berlin/steves-debian-setup),
which does the same job for a desktop. This one targets a **Pinebook A64**
(ARM64, 2 GB RAM) but runs unmodified on any apt + systemd host, arm64 or amd64.

Plain Bash, no runtime dependencies beyond the packages it installs, and every
package comes from apt. Only Tailscale adds a third-party repository.

## Quick start

```sh
git clone https://github.com/steve-berlin/steves-sbc-setup
cd steves-sbc-setup

./setup/wizard.sh                # ask what to install, configure and remove
```

The wizard walks through every script, collects the settings each one needs
(Tailscale key, restic repository, dfs address), shows the whole plan, and
applies nothing until you confirm.

Prefer it unattended? `bootstrap.sh` runs the provisioning stages straight
through, no questions:

```sh
./setup/bootstrap.sh --dry-run   # print every change, touch nothing
./setup/bootstrap.sh             # apply
```

Each stage is independently runnable and safe to re-run:

```sh
./setup/harden.sh --dry-run
sudo ./setup/backup.sh
```

Skip stages you don't want:

```sh
SKIP="tailscale monitor" ./setup/bootstrap.sh
```

## What it sets up

| Script | Does |
|---|---|
| `setup/base.sh` | Essential packages, chrony time sync, zram swap (zstd, 50% of RAM), unattended security upgrades |
| `setup/harden.sh` | sshd lockdown, kernel + network sysctl tuning (BBR, zram-aware VM), nftables default-deny firewall |
| `setup/tailscale.sh` | Official Tailscale repo + `tailscaled`, so you can reach the box from anywhere |
| `setup/podman.sh` | Rootless, daemonless container host with Quadlet units managed by systemd |
| `setup/shell.sh` | zsh (apt plugins, no framework) + tmux (plugin-free) + btop; `SHELL_RICH=1` adds starship + atuin |
| `setup/monitor.sh` | `prometheus-node-exporter` on `:9100`, reachable over the tailnet only |
| `setup/backup.sh` | Encrypted, deduplicated `restic` backups on a daily systemd timer |
| `setup/bootstrap.sh` | Runs all of the above, in dependency order |

Three more scripts sit outside `bootstrap.sh` — the wizard offers them, or run
them yourself:

| Script | Does |
|---|---|
| `setup/wizard.sh` | Interactive front end to all of the above: asks what to provision, install and remove, seeds the config files, confirms, then runs it |
| `setup/apps.sh` | Optional self-hosted apps (`APPS`, default `dfs navidrome`): [steves-domainless-filehosting](https://github.com/steve-berlin/steves-domainless-filehosting) built from source as a sandboxed service, and [Navidrome](https://www.navidrome.org/) (music server, Subsonic API) from the checksum-verified upstream `.deb` |
| `setup/remove-xfce.sh` | Purges an XFCE desktop off a box that should be headless, and switches the boot target to console. Destructive; asks first |

`lib/common.sh` holds the shared helpers: logging, `--dry-run` plumbing, sudo
re-exec, idempotent file installs, and apt wrappers.

## Docs

Plain-language, "explain it like I'm 11" walkthroughs live in [`docs/`](docs/),
one per script:

- [`docs/common.md`](docs/common.md) — the shared toolbox every script loads
- [`docs/base.md`](docs/base.md) — packages, clock, zram, auto-updates
- [`docs/harden.md`](docs/harden.md) — SSH, sysctl, firewall
- [`docs/tailscale.md`](docs/tailscale.md) — the mesh VPN
- [`docs/podman.md`](docs/podman.md) — rootless containers + Quadlet
- [`docs/shell.md`](docs/shell.md) — zsh + tmux
- [`docs/monitor.md`](docs/monitor.md) — node_exporter metrics
- [`docs/backup.md`](docs/backup.md) — restic backups
- [`docs/bootstrap.md`](docs/bootstrap.md) — the unattended runner, and why the stage order matters
- [`docs/wizard.md`](docs/wizard.md) — the interactive front end
- [`docs/apps.md`](docs/apps.md) — the optional apps (dfs, navidrome)
- [`docs/remove-xfce.md`](docs/remove-xfce.md) — stripping the desktop
- [`docs/line-by-line.md`](docs/line-by-line.md) — every function and operation, line by line

## Conventions

Every script:

- accepts `--dry-run` (print, change nothing) and `--help`
- is **idempotent** — re-running is a no-op when nothing has drifted
- re-execs itself under `sudo` when it needs root
- backs up any file it replaces to `<file>.bak.<epoch>`
- owns its own dependencies, so it works standalone

## Safety notes

**SSH.** `harden.sh` only disables password authentication once it finds a
non-empty `authorized_keys`. Without one it leaves password login on and warns,
so it cannot lock you out. Add your key, re-run it, and the lockdown completes.
Set `FORCE_SSH_KEYONLY=1` to override.

**Backups.** `backup.sh` generates a restic encryption key at
`/etc/restic/password` on first run. That key is the only way to decrypt your
backups — copy it off the machine. The backup timer stays disabled until you set
`RESTIC_REPOSITORY` in `/etc/restic/env`, then re-run the script.

**Firewall.** `harden.sh` installs a default-deny inbound ruleset that admits
only loopback, established connections, ICMP, DHCP replies, port 22, and
anything arriving on `tailscale0`. `monitor.sh` depends on this to keep `:9100`
off the public internet.

**Login shell.** `shell.sh` switches the owner's login shell to zsh (`chsh`) and
writes `~/.zshrc`, `~/.tmux.conf` and a seed `~/.config/btop/btop.conf` owned by
that user (btop rewrites its own config, so that one is written once and then
left alone). It takes effect on next
login; the old dotfiles are backed up. Set `SHELL_NO_CHSH=1` to keep your
current shell and only drop the config files. `SHELL_RICH=1` additionally
installs starship + atuin — the one path here that fetches from the internet
(they aren't in apt) — and writes a `~/.config/starship.toml` so starship is
configured, not just present. The default stays offline-clean.

**Apps.** `apps.sh` leaves `dfs.service` **disabled** until you set `DFS_PUBLIC`
in `/etc/dfs/env`: that value is both the address users reach and the name in the
self-signed TLS certificate, so an empty one serves nobody. Navidrome's admin
account is claimed by whoever loads `http://<host>:4533/` first, so open it
yourself once it is up. The firewall opens neither port, which keeps both apps on
the tailnet until you decide otherwise. Music lives in `/srv/music`
(`NAVIDROME_MUSIC` to change), owned by you, read-only to the service.

**Removing the desktop.** `remove-xfce.sh` *purges* — packages and their config,
with no undo. It prints the list and asks before acting (`XFCE_YES=1` skips the
prompt), refuses to run from inside a graphical session, and is deliberately not
part of `bootstrap.sh`. Preview with `--dry-run` first.

## Requirements

- an apt-based distro (Debian, Ubuntu, Armbian, Raspberry Pi OS) with systemd
- `sudo`
- ARM64 or AMD64

Development: `shellcheck -x setup/*.sh lib/common.sh` must pass clean.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
