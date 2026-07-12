# steves-sbc-setup — working notes

Provisioning scripts for headless servers/SBCs. Primary target: **Pinebook A64**
(Allwinner A64, ARM64, 2 GB RAM, eMMC/SD storage). Runs unmodified on any apt +
systemd host, arm64 or amd64.

Design constraints, priority order: **minimal** (few files, few lines, apt-only
deps), **idempotent**, **reversible** (everything replaced gets backed up),
**fast on weak hardware**.

## Layout

```
lib/common.sh      shared helpers — sourced, never executed
setup/base.sh      packages, chrony, zram, unattended-upgrades
setup/harden.sh    sshd, sysctl, nftables
setup/tailscale.sh mesh VPN
setup/podman.sh    rootless containers + Quadlet
setup/shell.sh     zsh + tmux for the box's owner
setup/monitor.sh   prometheus-node-exporter
setup/backup.sh    restic + systemd timer
setup/bootstrap.sh runs all stages in order
docs/              plain-language, per-script explanations (docs/shell.md, …)
```

## Conventions every script follows

- `--dry-run` and `--help`, parsed by `parse_common_args`.
- `require_root "$@"` re-execs under `sudo`, forwards `DRY_RUN` explicitly (not
  `sudo -E` — sudoers commonly strips it).
- `install_file DEST [MODE]` takes content on stdin, writes only when content
  differs, backs up what it replaces. `create_if_absent` (backup.sh only) never
  clobbers — those files hold secrets and operator intent.
- Each script `apt_install`s own deps, never assumes earlier stage ran. Stages
  independently runnable on purpose.
- Paths come from `SELF` / `SELF_DIR` / `REPO_DIR`, resolved in `common.sh` from
  `${BASH_SOURCE[-1]}` — entry script, not library.

## Gotchas — do not reintroduce

**`set -e` and guard clauses.** `[ cond ] && return 0` is trap: when `cond`
false, `&&` list yields 1, that becomes statement exit status, `set -e` kills
script. Silently broke `require_root` (never escalated) and `apt_update_once`
(died on first call). Always write guards as `if ...; then return 0; fi`.
Exception: function invoked in an `if` condition has `set -e` suspended inside —
but don't rely on that.

**`sh script` bypasses shebang.** `sh setup/foo.sh` ignores
`#!/usr/bin/env bash`, runs under dash, which dies on `set -o pipefail` and other
bashisms (arrays, `${BASH_SOURCE}`). Every entry script re-execs under bash via
`if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi`, placed *before*
`set -euo pipefail`. Keep guard first; must be plain POSIX so dash can parse it.

**sshd drop-ins silently ignored** unless `/etc/ssh/sshd_config` contains
`Include /etc/ssh/sshd_config.d/*.conf`. Debian ships it; hand-edited config may
not. `harden.sh` hard-fails on absence rather than writing a file that does
nothing.

**Never disable password auth blind.** `has_ssh_key` checks root's and target
user's `authorized_keys` for a non-comment line first. Skip this and remote
access on a headless box is bricked. `FORCE_SSH_KEYONLY=1` overrides.

**`sshd -t` before every reload.** Config that fails validation must not reach
`systemctl reload`. `nft -c -f` guards the firewall same way — a ruleset that
fails to load leaves the box with *no* firewall, worse than a wrong one.

**`rp_filter` must be 2 (loose), not 1 (strict).** Tailscale subnet routers and
exit nodes create legitimately asymmetric routes that strict reverse-path
filtering drops. Tailscale's own documented recommendation.

**BBR is a module, not a given.** `tcp_bbr` not built into every SBC kernel.
`harden.sh` probes `/proc/sys/net/ipv4/tcp_available_congestion_control`, emits
`bbr` + `fq` sysctls only when kernel supports them; otherwise `sysctl --system`
errors on unknown key. When BBR present, also writes
`/etc/modules-load.d/bbr.conf` so it survives reboot.

**zram, not swapfile.** 50% of RAM as zstd-compressed zram. On 2 GB board zstd
compresses typical anonymous pages roughly 3:1 — nets more usable memory than it
costs, never writes to eMMC/SD. `vm.swappiness` therefore **100**, not usual 10:
swapping to compressed RAM is cheap, better than evicting page cache.

**SBCs have no RTC battery.** Without chrony, clock boots at epoch and every
outbound TLS handshake fails on cert validity. `base.sh` enables it before
anything that fetches over HTTPS.

**Rootless podman needs three things**, missing any one fails confusingly:
1. `/etc/subuid` + `/etc/subgid` range, or every `podman run` dies in
   `newuidmap`. After adding one, `podman system migrate` required to drop cached
   empty mapping.
2. `loginctl enable-linger $USER`, or user's systemd instance torn down at logout
   and no container survives reboot.
3. podman **>= 4.4** for Quadlet. Debian bookworm ships 4.3 — script installs
   podman anyway and warns; fall back to `podman generate systemd` there.

Rootless podman uses pasta/slirp4netns, not a bridge, so nftables `forward` chain
needs no rules. Rootful podman *would*.

**Tailscale publishes for `debian` and `ubuntu` only.** Derivatives (Armbian,
Raspberry Pi OS, Mint) must map onto base they track; `detect_repo` does this via
`ID` then `ID_LIKE`, and `TS_DISTRO` / `TS_CODENAME` override. Script `curl -fsI`s
the keyring URL before writing the sources file, so unpublished codename fails
loudly instead of 404ing on every future `apt update`.

Tailscale installed and enabled but **not joined** — joining needs interactive
browser login. Set `TS_AUTHKEY` to join non-interactively.

**restic key loss is terminal.** `backup.sh` generates `/etc/restic/password` on
first run and prints loud warning. If SD card dies and key wasn't copied off-box,
backups unrecoverable. Timer stays **disabled** until `RESTIC_REPOSITORY` set —
backup job pointed at nothing is worse than none: looks green, protects nothing.

`repo_configured()` greps the env file rather than sourcing it: operator-editable,
and sourcing would execute whatever ended up in there.

restic unit uses `ProtectSystem=full`, not `strict`, so a repo on `/mnt` or `/srv`
still works. `ExecStartPre=-/usr/bin/restic init` succeeds once, returns nonzero
forever after; `-` prefix makes that non-fatal.

**node_exporter exposure is firewall's job.** Binds `0.0.0.0:9100`. `harden.sh`'s
default-deny ruleset confines it to `tailscale0`. `monitor.sh` warns if no ruleset
loaded. Don't "fix" by binding to the Tailscale IP — that address doesn't exist
until `tailscaled` comes up.

**Stage order in `bootstrap.sh` is load-bearing.** `harden` installs the rule
admitting `tailscale0` *before* `tailscale` brings the interface up, and `monitor`
relies on that same ruleset to keep `:9100` private.

**Shell config deliberately lean by default, unlike desktop repo.** `shell.sh`
default path avoids oh-my-zsh/starship/atuin and the tmux plugin manager: those
fetch from internet at setup time and cost startup latency on SD storage. Default
uses only apt packages (`zsh-syntax-highlighting`, `zsh-autosuggestions`) and
native zsh/tmux features, works offline. Do not make framework path the default —
reintroduces a network dependency into provisioning.

`SHELL_RICH=1` is opt-in escape hatch: installs starship (system-wide, via upstream
install script into `/usr/local/bin`) and atuin (into target user's `~/.atuin`,
`--no-modify-path`), appends guarded init lines to `~/.zshrc`. Init lines use
`command -v … && eval` so a missing binary never breaks the shell. starship
overrides native vcs_info prompt on purpose. Keep path opt-in; keep lean path
offline-clean.

**tmux `default-terminal` is `screen-256color`, not `tmux-256color`.** Latter needs
`ncurses-term`, absent on minimal SBC images, and colours break without it.
`screen-256color` is in base terminfo everywhere.

**zsh syntax-highlighting must be sourced last in `.zshrc`.** It wraps the line
editor and no-ops silently if anything sourced after it. Autosuggestions first,
highlighting last.

**Dotfiles written user-owned.** `install_file` takes optional third `OWNER` arg
(`user:group`); `shell.sh` uses it so `~/.zshrc` / `~/.tmux.conf` belong to target
user, not root — root-owned `.zshrc` is ignored by zsh. Owner is `target_user`
(`$SUDO_USER`/`$TARGET_USER`), same as podman.sh.

## Verifying changes

```sh
shellcheck -x setup/*.sh lib/common.sh    # must be clean
./setup/bootstrap.sh --dry-run            # must reach "bootstrap complete"
```

Validate generated artifacts directly — syntax error in them fails at runtime, not
lint time:

```sh
nft -c -f /etc/nftables.conf              # ruleset parses
systemd-analyze verify <unit>             # unit is valid
```

Sysctl keys confirmed present on kernel 6.12 (amd64). If a key vanishes on older
SBC kernel, `sysctl --system` errors on it — gate it the way BBR is.