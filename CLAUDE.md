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
setup/shell.sh     zsh + tmux + btop for the box's owner
setup/monitor.sh   prometheus-node-exporter
setup/backup.sh    restic + systemd timer
setup/bootstrap.sh runs all stages in order (unattended path)
setup/wizard.sh    interactive front end: prompts, seeds config, runs the rest
setup/apps.sh      optional self-hosted apps (dfs, navidrome) — NOT in bootstrap
setup/remove-xfce.sh  purge XFCE desktop — NOT in bootstrap, destructive
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

**sudo scrubs the environment.** `require_root` re-execs via `exec sudo`, and sudo
drops env vars (`sudo -E` commonly forbidden by sudoers). Every knob a script
reads must be listed in `SUDO_KEEP` (`lib/common.sh`) or it dies at the sudo
boundary — this silently broke `SHELL_RICH=1 ./setup/shell.sh`, which took the
lean path and left the operator wondering where starship went. Add an env var to
any script, add it to `SUDO_KEEP`.

**starship is installed *and* configured.** Binary alone falls back to the upstream
default preset, which probes a dozen language toolchains per prompt — slow on an
SBC. `configure_starship` writes a user-owned `~/.config/starship.toml` with an
explicit `format`, so unlisted modules never run. The `starship init zsh` line is
emitted *before* the plugin sources, keeping syntax-highlighting last.

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

**`wizard.sh` seeds config *before* the stage that reads it.** `/etc/restic/env`
and `/etc/dfs/env` are written from the answers, so `backup.sh` / `apps.sh` then
find a configured box and enable what they would otherwise leave disabled. Seeding
never clobbers — an existing env file is the operator's, possibly pointing at a
live repository. The wizard does **not** pass `XFCE_YES=1` to `remove-xfce.sh`:
one "yes" in the plan should not disarm both the remover's own prompt and its
graphical-session guard. It also does not need `SUDO_KEEP` — it re-execs under
sudo itself, so children inherit plain exported variables.

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

**btop config is seeded, not managed.** btop rewrites `~/.config/btop/btop.conf`
itself when it exits, so `install_file` would "restore" it on every re-run and pile
up `.bak` files. `configure_btop` writes it only when absent. Defaults are tuned
down (`update_ms = 2000`, no GPU box): btop refreshes 10×/s out of the box, which
is real CPU on an A64 when it lives in a tmux pane all day. btop belongs in
`shell.sh`, not `apps.sh` — apps.sh is for *services* (unit, user, port, firewall
note); btop is an apt-only interactive tool, and the lean shell path stays
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

**`apps.sh` builds dfs from source; the Go toolchain is the whole problem.**
dfs's `go.mod` pins a newer Go than Debian ships. Go >= 1.21 fixes that itself
(`GOTOOLCHAIN=auto` fetches the pinned toolchain), but **bookworm ships 1.19**,
which has neither `GOTOOLCHAIN` nor `go -C` and fails with `flag provided but not
defined: -C`. So `ensure_go` checks `go env GOVERSION` against `GO_MIN=1.21`, tries
apt, and otherwise installs the upstream tarball into `/usr/local/go` (sha256 taken
from `https://go.dev/dl/?mode=json` — the `.sha256` URLs serve HTML, not a hash).
Never use `go -C`; `cd` in a subshell instead. `-p 2` — Go's default of one compiler
per core OOMs a 2 GB board. Commit stamp (`/usr/local/src/.dfs-built`) — rebuild
only when the checked-out commit changed; a full Go build on a Pinebook is minutes.

`dfs.service` stays **disabled** until `DFS_PUBLIC` is set in `/etc/dfs/env`
(grepped, not sourced — same reason as restic). That value is the address users
reach *and* the CN of the self-signed cert; empty means a service at no address.
The firewall doesn't open its port, so dfs is tailnet-only by default — a public
file host should be a decision, not an accident. Data dir is `0700` and owned by
system user `dfs`: it holds `master.key` plus every user's ciphertext.

**Navidrome comes from the upstream `.deb`, not from source.** Building it pulls
Node in to compile the bundled web UI — absurd on a 2 GB board. The release asset
is `navidrome_<ver>_linux_<arch>.deb` (`arch`: amd64/arm64/armv7/386, *not* the
Debian arch string — `nd_asset_arch` maps it) and the checksum file is
`navidrome_checksums.txt`, **not** `checksums.txt` (that name 404s). `sha256sum -c`
gates the install; a mismatch dies. `apt-get install ./x.deb`, not `dpkg -i`, so
its `ffmpeg` dependency resolves. `latest` is resolved to a concrete tag once and
reused, so a mid-run upstream publish can't split the version across steps.

Navidrome's admin account belongs to the **first HTTP visitor**, so the script
warns loudly. Config `/etc/navidrome/navidrome.toml` is a dpkg conffile —
`install_file` backs up whatever upstream shipped before writing. Caches are
capped small (50/100 MB) because they land on eMMC/SD. `/srv/music` is owned by
`target_user`, not by the service: the library is the operator's, and navidrome
only reads it.

**`remove-xfce.sh` is the only destructive script here** — `apt purge` takes config
with it, and there is no undo. Hence: not in `bootstrap.sh`, prompts before acting
(`XFCE_YES=1` overrides), refuses when `$DISPLAY` is set (it would purge the
desktop out from under the terminal running it) and when stdin isn't a TTY. It
matches packages by *glob patterns*, not a fixed list, because names differ across
Debian/Ubuntu/Armbian images; libraries are left to `autoremove --purge`. Flips
`graphical.target` → `multi-user.target`, else boot stalls on a display manager
that no longer exists.

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