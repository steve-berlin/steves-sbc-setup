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
| `setup/shell.sh` | zsh (apt plugins, no framework) + tmux (plugin-free) for the box's owner |
| `setup/monitor.sh` | `prometheus-node-exporter` on `:9100`, reachable over the tailnet only |
| `setup/backup.sh` | Encrypted, deduplicated `restic` backups on a daily systemd timer |
| `setup/bootstrap.sh` | Runs all of the above, in dependency order |

`lib/common.sh` holds the shared helpers: logging, `--dry-run` plumbing, sudo
re-exec, idempotent file installs, and apt wrappers.

## Docs

Plain-language, "explain it like I'm 11" walkthroughs live in [`docs/`](docs/):

- [`docs/shell.md`](docs/shell.md) — why the zsh + tmux stage is built the way it is

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

## Requirements

- an apt-based distro (Debian, Ubuntu, Armbian, Raspberry Pi OS) with systemd
- `sudo`
- ARM64 or AMD64

Development: `shellcheck -x setup/*.sh lib/common.sh` must pass clean.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
