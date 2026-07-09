# steves-sbc-setup — working notes

Provisioning scripts for headless servers/SBCs. Primary target: **Pinebook A64**
(Allwinner A64, ARM64, 2 GB RAM, eMMC/SD storage). Written to run unmodified on
any apt + systemd host on arm64 or amd64.

Design constraints, in priority order: **minimal** (few files, few lines, apt-only
dependencies), **idempotent**, **reversible** (everything replaced gets backed
up), **fast on weak hardware**.

## Layout

```
lib/common.sh      shared helpers — sourced, never executed
setup/base.sh      packages, chrony, zram, unattended-upgrades
setup/harden.sh    sshd, sysctl, nftables
setup/tailscale.sh mesh VPN
setup/podman.sh    rootless containers + Quadlet
setup/monitor.sh   prometheus-node-exporter
setup/backup.sh    restic + systemd timer
setup/bootstrap.sh runs all stages in order
```

## Conventions every script follows

- `--dry-run` and `--help`, parsed by `parse_common_args`.
- `require_root "$@"` re-execs under `sudo`, forwarding `DRY_RUN` explicitly
  (not via `sudo -E`, which sudoers commonly strips).
- `install_file DEST [MODE]` takes content on stdin, writes only when the content
  actually differs, and backs up what it replaces. `create_if_absent` (backup.sh
  only) never clobbers, because those files hold secrets and operator intent.
- Each script `apt_install`s its own dependencies rather than assuming an earlier
  stage ran. Stages are independently runnable on purpose.
- Paths come from `SELF` / `SELF_DIR` / `REPO_DIR`, resolved in `common.sh` from
  `${BASH_SOURCE[-1]}` — the entry script, not the library.

## Gotchas — do not reintroduce

**`set -e` and guard clauses.** `[ cond ] && return 0` is a trap: when `cond` is
false the `&&` list yields 1, that is the statement's exit status, and `set -e`
kills the script. This silently broke `require_root` (never escalated) and
`apt_update_once` (died on first call). Always write guard clauses as
`if ...; then return 0; fi`. Exception: a function invoked in an `if` condition
has `set -e` suspended inside it — but don't rely on that.

**sshd drop-ins are silently ignored** unless `/etc/ssh/sshd_config` contains
`Include /etc/ssh/sshd_config.d/*.conf`. Debian ships it; a hand-edited config
may not. `harden.sh` hard-fails on its absence rather than writing a file that
does nothing.

**Never disable password auth blind.** `has_ssh_key` checks root's and the target
user's `authorized_keys` for a non-comment line first. Skipping this bricks
remote access on a headless box. `FORCE_SSH_KEYONLY=1` overrides.

**`sshd -t` before every reload.** A config that fails validation must not reach
`systemctl reload`, same reasoning as above. `nft -c -f` guards the firewall for
the same reason — a ruleset that fails to load leaves the box with *no*
firewall, which is worse than a wrong one.

**`rp_filter` must be 2 (loose), not 1 (strict).** Tailscale subnet routers and
exit nodes create legitimately asymmetric routes that strict reverse-path
filtering drops. This is Tailscale's own documented recommendation.

**BBR is a module, not a given.** `tcp_bbr` isn't built into every SBC kernel.
`harden.sh` probes `/proc/sys/net/ipv4/tcp_available_congestion_control` and only
emits the `bbr` + `fq` sysctls when the kernel supports them; otherwise
`sysctl --system` would error on an unknown key. When BBR is present it also
writes `/etc/modules-load.d/bbr.conf` so it survives reboot.

**zram, not a swapfile.** 50% of RAM as zstd-compressed zram. On a 2 GB board
zstd compresses typical anonymous pages roughly 3:1, so it nets more usable
memory than it costs, and it never writes to the eMMC/SD card. `vm.swappiness`
is therefore set to **100**, not the usual 10 — swapping to compressed RAM is
cheap and preferable to evicting page cache.

**SBCs have no RTC battery.** Without chrony the clock boots at the epoch and
every outbound TLS handshake fails on certificate validity. `base.sh` enables it
before anything that fetches over HTTPS.

**Rootless podman needs three things**, and missing any one fails confusingly:
1. an `/etc/subuid` + `/etc/subgid` range, or every `podman run` dies in
   `newuidmap`. After adding one, `podman system migrate` is required to drop the
   cached empty mapping.
2. `loginctl enable-linger $USER`, or the user's systemd instance is torn down at
   logout and no container survives a reboot.
3. podman **>= 4.4** for Quadlet. Debian bookworm ships 4.3 — the script installs
   podman anyway and warns; fall back to `podman generate systemd` there.

Rootless podman uses pasta/slirp4netns, not a bridge, so the nftables `forward`
chain needs no rules. Rootful podman *would*.

**Tailscale publishes for `debian` and `ubuntu` only.** Derivatives (Armbian,
Raspberry Pi OS, Mint) must be mapped onto the base they track; `detect_repo`
does this via `ID` then `ID_LIKE`, and `TS_DISTRO` / `TS_CODENAME` override it.
The script `curl -fsI`s the keyring URL before writing the sources file, so an
unpublished codename fails loudly instead of 404ing on every future `apt update`.

Tailscale is installed and enabled but **not joined** — joining needs an
interactive browser login. Set `TS_AUTHKEY` to join non-interactively.

**restic's key loss is terminal.** `backup.sh` generates `/etc/restic/password`
on first run and prints a loud warning. If the SD card dies and that key wasn't
copied off-box, the backups are unrecoverable. The timer stays **disabled** until
`RESTIC_REPOSITORY` is set, because a backup job pointed at nothing is worse than
no backup job — it looks green and protects nothing.

`repo_configured()` greps the env file rather than sourcing it: it's
operator-editable, and sourcing would execute whatever ended up in there.

The restic unit uses `ProtectSystem=full`, not `strict`, so a repository on
`/mnt` or `/srv` still works. `ExecStartPre=-/usr/bin/restic init` succeeds once
and returns nonzero forever after; the `-` prefix makes that non-fatal.

**node_exporter's exposure is the firewall's job.** It binds `0.0.0.0:9100`.
`harden.sh`'s default-deny ruleset is what confines it to `tailscale0`.
`monitor.sh` warns if no ruleset is loaded. Don't "fix" this by binding it to the
Tailscale IP — that address doesn't exist until `tailscaled` has come up.

**Stage order in `bootstrap.sh` is load-bearing.** `harden` installs the rule
admitting `tailscale0` *before* `tailscale` brings the interface up, and
`monitor` relies on that same ruleset to keep `:9100` private.

## Verifying changes

```sh
shellcheck -x setup/*.sh lib/common.sh    # must be clean
./setup/bootstrap.sh --dry-run            # must reach "bootstrap complete"
```

Generated artifacts are worth validating directly, since a syntax error in them
fails at runtime rather than at lint time:

```sh
nft -c -f /etc/nftables.conf              # ruleset parses
systemd-analyze verify <unit>             # unit is valid
```

Sysctl keys were confirmed present on kernel 6.12 (amd64). If a key vanishes on
an older SBC kernel, `sysctl --system` errors on it — gate it the way BBR is.
