# Line-by-line, explained like you're 11

Deep version. Every function, every operation, plain language. Want short "what stage do," read per-stage docs instead (`base.md`, `harden.md`, …). This file for "what does *this line* do, and why."

Long. Use table of contents.

- [The header every script shares](#the-header-every-script-shares)
- [`lib/common.sh` — the toolbox](#libcommonsh--the-toolbox)
- [`setup/base.sh`](#setupbasesh)
- [`setup/harden.sh`](#setuphardensh)
- [`setup/tailscale.sh`](#setuptailscalesh)
- [`setup/podman.sh`](#setuppodmansh)
- [`setup/shell.sh`](#setupshellsh)
- [`setup/monitor.sh`](#setupmonitorsh)
- [`setup/backup.sh`](#setupbackupsh)
- [`setup/bootstrap.sh`](#setupbootstrapsh)

---

## The header every script shares

Every `setup/*.sh` starts with same four lines. Learn once:

```bash
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
```

**`#!/usr/bin/env bash`** — "shebang." Run file, system read first line to know *what program* interpret it. `/usr/bin/env bash` = "find bash on PATH, use it." `env` instead of hard-coded `/bin/bash` = portable to systems where bash live elsewhere.

**`if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi`** — self-defence guard. Someone start script with `sh setup/foo.sh` instead of `./setup/foo.sh`, `sh` overrides shebang and script run under dash, which can't do `pipefail` or bash tricks below. `$BASH_VERSION` only set when bash running, so `[ -z ... ]` ("empty?") detects dash and `exec bash "$0" "$@"` restarts same script under bash. Line itself plain POSIX so dash can read it. Written *before* `set -o pipefail` on purpose — must run before line that would otherwise crash.

**`set -euo pipefail`** — four safety switches at once. Single most important line for correctness:

- `-e` — **exit on error.** Any command fails, stop whole script right there. No blundering onward after break.
- `-u` — **error on undefined variables.** Type `$USERNAM` when you meant `$USERNAME`, script stops instead of silently using empty string. Catches typos.
- `-o pipefail` — in pipe `a | b`, normally only `b`'s success counts. With this, `a` fails = whole pipe fails. Without it, failures hide mid-pipe.
- (`-o` = switch that turns on named option `pipefail`.)

Catch: `-e` caused nastiest bug in project — see `require_root` below.

**`# shellcheck source=../lib/common.sh`** — note to *shellcheck*, the linter. Bash ignore it (comment). Tells linter "next line pulls in this file, go read it so you understand these functions." Keeps lint clean.

**`. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"`** — loads shared toolbox. Read inside-out:

- `$0` = path used to run this script (e.g. `./setup/base.sh`).
- `readlink -f "$0"` = full real path, symlinks resolved (e.g. `/home/steve/steves-sbc-setup/setup/base.sh`).
- `dirname ...` strips filename, leaves folder (`/home/steve/steves-sbc-setup/setup`).
- `/../lib/common.sh` steps up one folder, into `lib/common.sh`.
- Leading `.` (dot, same as `source`) = "run that file *in this shell*," so its functions and variables become available here.

Whole dance exist so script finds toolbox no matter what folder you run from.

Every script *ends* with same three lines:

```bash
parse_common_args "$@"
require_root "$@"
main
```

Parse flags, become root if needed, do work. `"$@"` = "all arguments you were given," passed along untouched.

---

## `lib/common.sh` — the toolbox

Not run alone — shared box of tools every stage borrows from.

```bash
set -euo pipefail
```
Same safety switches, so tools strict too.

### Finding its own location (lines 8–11)

```bash
SELF="$(readlink -f "${BASH_SOURCE[-1]}")"
SELF_DIR="$(dirname "$SELF")"
REPO_DIR="$(dirname "$SELF_DIR")"
export SELF SELF_DIR REPO_DIR
```

`${BASH_SOURCE[-1]}` clever bit. `BASH_SOURCE` = list of files in current call chain; `[-1]` = *last* one — original script you actually ran (like `base.sh`), **not** this library. So `SELF` = full path of entry script, `SELF_DIR` its folder (`setup/`), `REPO_DIR` folder above (repo root). `export` makes these visible to programs script launches. `require_root` uses `SELF` to re-launch *right* script under sudo.

### Colors (lines 14–18)

```bash
if [ -t 2 ]; then
	C_R=$'\e[31m' C_G=$'\e[32m' ...
else
	C_R='' C_G='' ...
fi
```

`[ -t 2 ]` asks "is 'standard error' a real terminal?" (2 = stderr). Yes: set variables to magic codes that make text red/green/etc. Output piped to file or another program: set empty — no one want `\e[31m` gibberish in log file. `$'\e[31m'` = bash way of writing escape character plus color code.

### The four message functions (lines 19–22)

```bash
log()  { printf '%s==>%s %s\n'  "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
```

Four ways to print message. `log` = blue "what I do now," `ok` = green success, `warn` = yellow caution, `die` = red error *then quit* (`exit 1` = "stop with failure code"). `%s` = placeholder printf fills with arguments; `$*` = "all words passed to this function"; `$C_0` resets color to normal. `>&2` sends message to stderr — "messages" channel, kept separate from actual output so two don't mix.

### The dry-run switch (lines 24–33)

```bash
DRY_RUN="${DRY_RUN:-0}"
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '%s[dry]%s %s\n' "$C_Y" "$C_0" "$*" >&2
	else
		"$@"
	fi
}
```

`DRY_RUN="${DRY_RUN:-0}"` = "DRY_RUN already set, keep it; otherwise make it 0 (off)." `run` = heart of dry-run mode: hand it command, dry-run on = just *print* command in yellow; off = `"$@"` actually *runs* it. Every dangerous action wrapped in `run` becomes harmless preview during rehearsal.

### Parsing the flags (lines 37–46)

```bash
parse_common_args() {
	local a
	for a in "$@"; do
		case "$a" in
			--dry-run) DRY_RUN=1 ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown argument: $a (try --help)" ;;
		esac
	done
}
```

Walk each argument. `--dry-run` flips on rehearsal mode. `-h`/`--help` prints usage text (each script defines own `usage`) and quits happily (`exit 0`). Anything else (`*` = "any other value") = typo, so `die` with helpful message. `local a` keeps loop variable from leaking out and clobbering something else.

### Becoming root

```bash
SUDO_KEEP=(
	DRY_RUN SKIP TARGET_USER
	FORCE_SSH_KEYONLY
	TS_AUTHKEY TS_DISTRO TS_CODENAME
	SHELL_RICH SHELL_NO_CHSH
	APPS DFS_REPO DFS_REF
	XFCE_YES XFCE_PURGE_X
)

require_root() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	command -v sudo >/dev/null 2>&1 || die "root required and sudo not found"
	local pass=() v
	for v in "${SUDO_KEEP[@]}"; do
		if [ -n "${!v+x}" ]; then
			pass+=("$v=${!v}")
		fi
	done
	log "re-executing under sudo…"
	exec sudo "${pass[@]}" "$SELF" "$@"
}
```

`id -u` prints user-number; 0 = root. So "already root, done." Otherwise: `command -v sudo` checks sudo exists (`>/dev/null 2>&1` throws away output — only care whether it *succeeds*), if not, `die`. Then `exec sudo ... "$SELF" "$@"` **replaces** current script with new one running as root — same script (`$SELF`), same arguments (`$@`). `exec` = "become that new process," so nothing after this line runs in old one.

**Why `SUDO_KEEP`?** sudo throws your environment variables away on purpose — that's a security feature, and `sudo -E` (keep everything) is usually forbidden by sudoers. So every knob has to be handed over *by name* on the sudo command line, as `NAME=value` pairs before the script path. Loop builds that list: `${!v+x}` = "is variable named by `v` set at all?" (indirect lookup — `v` holds a *name*, `${!v}` fetches that name's value; the `+x` form is true even when the value is empty). Only set ones get passed.

This bit us for real: `SHELL_RICH=1 ./setup/shell.sh` used to sudo-jump and land with `SHELL_RICH` gone, so it quietly took the plain path and you wondered why starship never showed up. Add a new env knob to any script → add it here too, or it dies at the sudo boundary.

**Why long `if` instead of `[ "$(id -u)" -eq 0 ] && return 0`?** *The* bug from earlier. Under `set -e`, write `test && return 0` and test is *false* = whole `&&` line counts as failed command — `-e` kills script on spot. So short version quietly *exited* instead of continuing to sudo line, meaning script never became root. Verbose `if ...; then return; fi` form avoids trap. Pattern used everywhere in repo for exactly this reason.

### Platform guard (lines 62–65)

```bash
require_apt_systemd() {
	command -v apt-get >/dev/null 2>&1 || die "unsupported: needs an apt distro ..."
	[ -d /run/systemd/system ] || die "unsupported: systemd is required"
}
```

Refuse to run where scripts don't fit. `command -v apt-get` checks Debian-family. `[ -d /run/systemd/system ]` checks systemd is init system (folder only exists when systemd running). Either missing → `die` with clear reason instead of failing weirdly ten steps later.

### Two tiny helpers (lines 68–71)

```bash
arch() { dpkg --print-architecture; }
target_user() { printf '%s' "${SUDO_USER:-${TARGET_USER:-}}"; }
```

`arch` prints `arm64` or `amd64`. `target_user` answers "who is human that owns this box?" — scripts run as root, so it looks at `SUDO_USER` (account that *called* sudo), falls back to `TARGET_USER` if set, falls back to empty. `${A:-${B:-}}` nesting = "use A, or if empty use B, or if that empty use nothing."

### apt helpers (lines 74–94)

```bash
apt_update_once() {
	if [ -n "${_APT_UPDATED:-}" ]; then
		return 0
	fi
	run apt-get update
	_APT_UPDATED=1
}
```

`apt-get update` (refreshing package list) slow, and several stages might want it. Runs *at most once* per script: `_APT_UPDATED` = flag; `[ -n ... ]` = "non-empty?" Already set, skip. Otherwise update, set flag. (Same verbose-`if` guard, same `set -e` reason.)

```bash
apt_install() {
	local p miss=()
	for p in "$@"; do
		dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p")
	done
	if [ ${#miss[@]} -eq 0 ]; then
		ok "packages present: $*"
		return 0
	fi
	apt_update_once
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"
}
```

Install packages, but *only missing ones* — that what makes re-runs fast and quiet. `miss=()` = empty list. For each requested package, `dpkg -s` checks if installed; if not (`||`), add to `miss`. `${#miss[@]}` = "how many items in miss"; zero = everything already there, say so and return. Otherwise update package list, then install. `DEBIAN_FRONTEND=noninteractive` tells apt "don't stop to ask questions" (vital for unattended script). `-y` = "yes to prompts." `--no-install-recommends` = "install *only* what I asked, not pile of optional extras" — keeps lean box lean.

### The idempotent file writer (lines 100–126)

```bash
install_file() {
	local dest="$1" mode="${2:-0644}" owner="${3:-}" tmp
	tmp="$(mktemp)"
	cat >"$tmp"
```

Workhorse. Takes destination path, optional permission mode (default `0644` = owner-writes, everyone-reads), optional owner. `mktemp` makes safe temp file; `cat >"$tmp"` pours content (piped in from calling script via `<<EOF`) into it.

```bash
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		ok "unchanged: $dest"
		return 0
	fi
```

**Idempotent bit.** Destination already exists *and* `cmp -s` (silent byte-by-byte compare) says new content identical = nothing to do — delete temp file, report "unchanged," done. Re-running changes nothing.

```bash
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would write $dest (mode $mode${owner:+, owner $owner}):"
		sed 's/^/      /' "$tmp" >&2
		rm -f "$tmp"
		return 0
	fi
```

Rehearsal mode: don't write, just show what *would* be written. `sed 's/^/      /'` adds six spaces to start of every line so preview clearly indented. `${owner:+, owner $owner}` = "owner set, print `, owner X`; otherwise print nothing" — neat way to mention ownership only when it matters.

```bash
	if [ -f "$dest" ]; then
		cp -a "$dest" "$dest.bak.$(date +%s)"
		warn "backed up existing $dest"
	fi
```

**Reversible bit.** About to overwrite real file, first copy to `<file>.bak.<number>`, where `$(date +%s)` = current time in seconds (unique-ish stamp). `cp -a` preserves original's permissions and ownership. Nothing ever destroyed without copy.

```bash
	if [ -n "$owner" ]; then
		install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
	else
		install -D -m "$mode" "$tmp" "$dest"
	fi
	rm -f "$tmp"
	ok "wrote $dest"
}
```

Finally, place file. `install -D` copies it and creates missing parent folders, `-m` sets permission mode. Owner given: `-o` sets user, `-g` group: `${owner%%:*}` chops everything from first `:` onward (leaves user), `${owner##*:}` chops everything up to last `:` (leaves group). So `steve:steve` becomes `-o steve -g steve`. Clean up temp file, report success.

### One-liner (line 129)

```bash
enable_now() { run systemctl enable --now "$1"; }
```

"Turn service on now *and* set it to start every boot." `enable` = start at boot, `--now` = also start this instant. Wrapped in `run` so it obeys dry-run.

---

## `setup/base.sh`

Turns utilities on. After shared header:

### `setup_zram` (lines 24–34)

```bash
setup_zram() {
	log "configuring zram swap"
	apt_install zram-tools
	install_file /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
	enable_now zramswap.service
}
```

Install `zram-tools`, write its config. `<<'EOF' ... EOF` = "heredoc" — everything between markers fed as input to `install_file`, becomes file's content. Quotes around `'EOF'` = "no variable substitution in here, take it literally." Settings: `ALGO=zstd` (compression method — fast, effective), `PERCENT=50` (use half of RAM for compressed swap), `PRIORITY=100` (prefer this swap over any other). Then turn service on. See `base.md` for *why* compressed swap right call on 2 GB board.

### `setup_auto_upgrades` (lines 38–48)

```bash
	install_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Install `unattended-upgrades`, switch on via this config. Three lines mean: refresh package list daily (`"1"` = every 1 day), apply unattended upgrades daily, clean out old downloaded packages every 7 days. By default `unattended-upgrades` only touches *security* archive, so this stays to security patches — nothing that reboots you into surprise new kernel.

### `main` (lines 50–64)

```bash
main() {
	require_apt_systemd
	log "base provisioning on $(arch)"
	apt_install ca-certificates curl gnupg chrony
	enable_now chrony.service
	setup_zram
	setup_auto_upgrades
	ok "base provisioning complete"
}
```

Check platform, announce architecture, install essentials (`ca-certificates` = list of trustable web certificate authorities, `curl` = download tool, `gnupg` = signature verification, `chrony` = clock fixer), turn clock service on *first* (so later HTTPS downloads don't fail on 1970 date — see `base.md`), then two helper functions. Done.

---

## `setup/harden.sh`

Locks doors. Three functions, three layers.

### `has_ssh_key` (lines 30–42)

```bash
has_ssh_key() {
	local u home f
	for u in root "$(target_user)"; do
		[ -n "$u" ] || continue
		home="$(getent passwd "$u" | cut -d: -f6)" || continue
		[ -n "$home" ] || continue
		f="$home/.ssh/authorized_keys"
		if [ -s "$f" ] && grep -qE '^[^#[:space:]]' "$f"; then
			return 0
		fi
	done
	return 1
}
```

Answers "does anyone have login key installed?" — guard that stops you locking yourself out. Checks two accounts: `root` and box's owner. For each: `[ -n "$u" ] || continue` skips empty names (no owner set). `getent passwd "$u" | cut -d: -f6` looks up user's record, grabs field 6, home directory (`getent` reads account database; `cut -d: -f6` splits on `:`, takes 6th piece). Then looks at `~/.ssh/authorized_keys`: `[ -s "$f" ]` = "exists and non-empty," `grep -qE '^[^#[:space:]]'` = "has at least one line that isn't blank or comment" (real key). If so, `return 0` (success — "yes, key exists"). Neither account has one: `return 1` (failure — "no keys"). In shell, 0 = true/success, non-zero = false.

### `harden_ssh` (lines 44–89)

```bash
	apt_install openssh-server
	if [ "$DRY_RUN" = 1 ] && [ ! -f /etc/ssh/sshd_config ]; then
		warn "[dry] openssh-server not installed — skipping sshd checks"
		return 0
	fi
```

Make sure SSH server installed (stage owns its own dependency so it works standalone). `if` handles rehearsal on box where SSH not installed yet: during dry-run nothing actually installed, so no config to check — skip gracefully instead of erroring.

```bash
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
		die "/etc/ssh/sshd_config lacks an Include for sshd_config.d — ..."
	fi
```

Our hardening goes into *drop-in* file in `sshd_config.d/` folder. But SSH only reads that folder if main config says to, via `Include` line. This greps for that line; missing = our file silently ignored — dangerous illusion of security — so we `die` and tell you to fix it. Better to fail loudly than to *think* you're hardened when you're not.

```bash
	local pw_auth='yes' note='# password auth LEFT ENABLED: ...'
	if has_ssh_key || [ "${FORCE_SSH_KEYONLY:-0}" = 1 ]; then
		pw_auth='no'
		note='# password auth disabled: key-based login verified'
	else
		warn "no authorized_keys found — leaving PasswordAuthentication enabled"
		warn "add a key, then re-run harden.sh to complete the lockdown"
	fi
```

Safety decision. Default: leave passwords *on* (`pw_auth='yes'`). Switch off only if `has_ssh_key` says key exists **or** you forced with `FORCE_SSH_KEYONLY=1`. No key, no force? Warn, leave passwords on. This makes it impossible to strand yourself.

```bash
	install_file /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<EOF
...
PasswordAuthentication $pw_auth
...
EOF
```

Write drop-in. Note heredoc is `<<EOF` *without* quotes, so `$pw_auth` and `$note` get substituted with values chosen above. Settings: `PermitRootLogin no` (no direct root), `PasswordAuthentication $pw_auth` (on or off per decision), `KbdInteractiveAuthentication no` and `PermitEmptyPasswords no` (close other password-ish doors), `MaxAuthTries 3` (three guesses then disconnect), `LoginGraceTime 20` (20 seconds to log in or dropped), `X11Forwarding no` (no graphical forwarding — pointless on headless box, one less attack surface).

```bash
	if [ "$DRY_RUN" != 1 ]; then
		sshd -t || die "sshd config validation failed — not reloading"
	fi
	enable_now ssh.service
	run systemctl reload ssh.service
```

`sshd -t` **tests** config for errors. Fails: `die` *without* reloading — reloading broken SSH config on remote box is how you lose access forever. Only if test passes do we ensure SSH enabled and `reload` it (reload applies new config without dropping existing connections).

### `sysctl_tuning` (lines 93–146)

```bash
	local cc_lines=''
	if [ "$DRY_RUN" != 1 ]; then
		modprobe tcp_bbr 2>/dev/null || true
	fi
	if [ "$DRY_RUN" = 1 ] || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		cc_lines=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
		install_file /etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF
	else
		warn "kernel has no BBR support — leaving congestion control at default"
	fi
```

BBR = faster network algorithm, but kernel *module* not on every board. `modprobe tcp_bbr` tries to load it (`2>/dev/null || true` = "ignore any error, don't stop script"). Then check: does kernel now list `bbr` as available? `grep -qw bbr /proc/.../tcp_available_congestion_control` looks for whole word `bbr` in that special kernel file. Yes (or just rehearsing): prepare two config lines in `cc_lines` — enabling BBR and companion queueing method `fq` — *and* write `modules-load.d` file so module loads automatically every boot. BBR *not* available: skip and warn, because writing sysctl for feature kernel lacks would make whole config fail to apply. `cc_lines` gets injected into big config below; `$'...\n...'` = bash way of putting real newline in string.

```bash
	install_file /etc/sysctl.d/99-sbc.conf <<EOF
...
vm.swappiness = 100
...
$cc_lines
...
net.ipv4.conf.all.rp_filter = 2
...
EOF
	run sysctl --system
```

Write all kernel dials into one file (unquoted heredoc so `$cc_lines` expands), then `sysctl --system` applies every setting immediately. Values and *why* each one (especially `swappiness = 100` and `rp_filter = 2`) covered in `harden.md`.

### `setup_firewall` (lines 150–198)

```bash
	apt_install nftables
	install_file /etc/nftables.conf 0644 <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		...
	}
	...
}
EOF
```

Install firewall tool, write ruleset. Reading rules:

- `flush ruleset` — wipe existing rules first, start clean.
- `table inet filter` — container for rules covering both IPv4 and IPv6 (`inet`).
- `chain input { ... policy drop; }` — rules for *incoming* traffic; `policy drop` = crucial default: **anything not explicitly allowed is rejected.**
- `ct state established,related accept` — allow replies to connections *you* started (`ct` = connection tracking).
- `ct state invalid drop` — throw away malformed/nonsense packets.
- `iif lo accept` — allow machine to talk to itself (`lo` = loopback).
- `iifname "tailscale0" accept` — allow *everything* arriving over Tailscale interface (that traffic already encrypted and authenticated).
- `meta l4proto icmp accept` (and `ipv6-icmp`) — allow ping and, more importantly, path-MTU messages real connections depend on.
- `udp dport 68 accept` — allow DHCP replies so box can get IP address.
- `tcp dport 22 accept` — allow SSH.
- `chain forward { ... policy drop; }` — traffic *routed through* box: denied (this box isn't router; rootless Podman doesn't need it).
- `chain output { ... policy accept; }` — *outgoing* traffic: allowed freely.

```bash
	if [ "$DRY_RUN" != 1 ]; then
		nft -c -f /etc/nftables.conf || die "nftables ruleset failed validation — not enabling"
	fi
	enable_now nftables.service
```

`nft -c -f` **checks** ruleset parses correctly *without* loading it. Broken: `die` — firewall that fails to load leaves you with *no* firewall, and one that loads wrong could lock out SSH. Only valid ruleset gets enabled. `main` (lines 200–206) just calls three layers in order.

---

## `setup/tailscale.sh`

Secret tunnel. Interesting work is picking right package repo.

### `detect_repo` (lines 31–54)

```bash
	# shellcheck disable=SC1091
	. /etc/os-release
```

`/etc/os-release` = file of variables describing distro (`ID=debian`, `VERSION_CODENAME=bookworm`, etc.). Sourcing with `.` loads those variables into script. (`# shellcheck disable=SC1091` tells linter "yes I know I'm sourcing file you can't follow, fine.")

```bash
	TS_DISTRO="${TS_DISTRO:-}"
	if [ -z "$TS_DISTRO" ]; then
		case "${ID:-}" in
			debian|raspbian) TS_DISTRO=debian ;;
			ubuntu|linuxmint|pop) TS_DISTRO=ubuntu ;;
			*)
				case " ${ID_LIKE:-} " in
					*" ubuntu "*) TS_DISTRO=ubuntu ;;
					*" debian "*) TS_DISTRO=debian ;;
					*) die "cannot map ID='${ID:-?}' onto a Tailscale repo — set TS_DISTRO=debian|ubuntu" ;;
				esac
				;;
		esac
	fi
```

Tailscale only publishes packages for `debian` and `ubuntu`, but lots of distros are those two in disguise. So: haven't forced `TS_DISTRO` yourself (`[ -z ... ]` = "empty?"), figure it out. First check `ID` directly — `debian` and `raspbian` map to debian; `ubuntu`, `linuxmint`, `pop` map to ubuntu. `ID` something else (`*`): fall back to `ID_LIKE`, which lists parent distros — `*" ubuntu "*` pattern (note spaces) checks if "ubuntu" appears as word in that list. Still no match? `die`, ask you to set manually. This is how it handles Armbian and friends.

```bash
	TS_CODENAME="${TS_CODENAME:-${VERSION_CODENAME:-}}"
	[ -n "$TS_CODENAME" ] || die "no VERSION_CODENAME in /etc/os-release — set TS_CODENAME"
```

Codename (like `bookworm`) picks *which version's* repo. Use your override if set, else one from os-release, else `die`.

### `add_repo` (lines 56–80)

```bash
	local base="https://pkgs.tailscale.com/stable/$TS_DISTRO/$TS_CODENAME"
	if [ "$DRY_RUN" != 1 ] && ! curl -fsI "$base.noarmor.gpg" >/dev/null 2>&1; then
		die "Tailscale publishes no repo for $TS_DISTRO/$TS_CODENAME — ..."
	fi
```

Build repo URL from distro + codename we detected. Then `curl -fsI` does *headers-only* test fetch of signing key (`-I` = "just check it's there, don't download," `-f` = "fail on 404," `-s` = "quietly"). Fails: repo doesn't exist for your system — `die` now, rather than writing broken repo that makes every future `apt update` spew 404 errors.

```bash
	if [ -s "$KEYRING" ]; then
		ok "unchanged: $KEYRING"
	else
		run curl -fsSL "$base.noarmor.gpg" -o "$KEYRING"
		run chmod 0644 "$KEYRING"
	fi
```

Download signing key (thing that proves packages really came from Tailscale) — only if not already there (`[ -s ... ]` = "exists and non-empty"), keeping run idempotent. `-o` saves to keyring path; `chmod 0644` makes world-readable (apt needs to read it).

```bash
	if [ -s "$LIST" ]; then
		ok "unchanged: $LIST"
	else
		run curl -fsSL "$base.tailscale-keyring.list" -o "$LIST"
		run chmod 0644 "$LIST"
		_APT_UPDATED=
	fi
```

Same pattern for sources list (file that tells apt "Tailscale repo over here"). `_APT_UPDATED=` clears "already updated apt" flag — we just added new repo, so next `apt_install` *must* run `apt-get update` again to see it.

### `join_tailnet` (lines 82–94)

```bash
	if [ "$DRY_RUN" != 1 ] && tailscale status >/dev/null 2>&1; then
		ok "already joined to a tailnet as $(tailscale ip -4 2>/dev/null || echo '?')"
		return
	fi
	if [ -n "${TS_AUTHKEY:-}" ]; then
		log "joining tailnet with supplied auth key"
		run tailscale up --authkey "$TS_AUTHKEY" --ssh
		...
		return
	fi
	warn "not joined to a tailnet yet — run: sudo tailscale up"
```

Already logged in (`tailscale status` succeeds): report machine's Tailscale IP and stop. Otherwise, if you supplied auth key, use it to join non-interactively (`--ssh` also turns on Tailscale's SSH feature). No key? We *can't* log in for you (needs browser), so warn and tell you command. `main` (lines 96–105) wires it together: install prerequisites, detect repo, add it, install tailscale, enable service, try to join.

---

## `setup/podman.sh`

Container house. Several small guard functions, each fixing one rootless gotcha.

### `user_home` (line 29)

```bash
user_home() { getent passwd "$1" | cut -d: -f6; }
```

Look up user's home directory (same `getent | cut -f6` trick as before). `$1` = "first argument passed to this function."

### `ensure_subids` (lines 33–44)

```bash
	if grep -q "^$u:" /etc/subuid 2>/dev/null && grep -q "^$u:" /etc/subgid 2>/dev/null; then
		ok "subuid/subgid present for $u"
		return 0
	fi
	log "allocating subuid/subgid range for $u"
	apt_install uidmap
	run usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$u"
	run runuser -u "$u" -- podman system migrate
```

Rootless containers need block of "sub-user-IDs" delegated to your user. Check whether `/etc/subuid` and `/etc/subgid` already have line starting with your username (`grep -q "^$u:"`); both do = nothing to do. Otherwise install `uidmap` (tool that makes mapping work), then `usermod --add-subuids ...` hands your user IDs 100000–165535 to use inside containers. Finally `runuser -u "$u" -- podman system migrate` runs podman command *as that user* (`runuser` = "run as another user," `--` separates its options from command) to make podman forget old cached "you have no IDs" answer. Skip this last step and containers keep failing even after mapping fixed.

### `ensure_linger` (lines 48–56)

```bash
	if [ "$DRY_RUN" != 1 ] && loginctl show-user "$u" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
		ok "lingering already enabled for $u"
		return 0
	fi
	log "enabling lingering for $u"
	run loginctl enable-linger "$u"
```

"Lingering" lets user's services keep running when they're not logged in — essential on headless box, or containers die at every reboot. Check current state (`loginctl show-user ... -p Linger` prints `Linger=yes` or `no`); already on = done. Otherwise `enable-linger`.

### `ensure_quadlet_dir` (lines 58–67)

```bash
	dir="$(user_home "$u")/.config/containers/systemd"
	if [ -d "$dir" ]; then
		ok "unchanged: $dir"
		return 0
	fi
	log "creating Quadlet unit directory $dir"
	run runuser -u "$u" -- mkdir -p "$dir"
```

Quadlet reads container definitions from this specific folder in user's home. Already exists = done; otherwise create it *as the user* (so they own it, not root). `mkdir -p` creates missing parent folders too.

### `check_quadlet_support` (lines 69–78)

```bash
	ver="$(podman --version 2>/dev/null | awk '{print $3}')" || ver=''
	[ -n "$ver" ] || { warn "cannot determine podman version"; return 0; }
	if dpkg --compare-versions "$ver" ge "$QUADLET_MIN"; then
		ok "podman $ver supports Quadlet"
	else
		warn "podman $ver is older than $QUADLET_MIN — Quadlet unavailable on this release"
	fi
```

Quadlet needs podman ≥ 4.4. `podman --version` prints like "podman version 4.9.3"; `awk '{print $3}'` grabs third word, the number. Can't get it: warn, move on. `dpkg --compare-versions "$ver" ge "4.4"` = proper version comparison (`ge` = "greater than or equal"); either reassures you or warns you're on older release where you'll use `podman generate systemd` instead. Only *warns* — never blocks setup.

### `main` (lines 80–110)

```bash
	u="$(target_user)"
	[ -n "$u" ] || die "no unprivileged user found — run via sudo, or set TARGET_USER"
	id "$u" >/dev/null 2>&1 || die "user '$u' does not exist"
```

Figure out owner, sanity-check it: non-empty, real account (`id "$u"` succeeds only for real user). Then install podman, check Quadlet support, run three `ensure_` guards. Closing `cat >&2 <<EOF ... EOF` just prints worked example of Quadlet file so you know what to do next. (`cat >&2` prints block to messages channel.)

---

## `setup/shell.sh`

zsh + tmux, all inside one `main`.

```bash
	u="$(target_user)"
	[ -n "$u" ] || die "..."
	id "$u" >/dev/null 2>&1 || die "..."
	home="$(getent passwd "$u" | cut -d: -f6)"
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		die "no home directory for '$u'"
	fi
	grp="$(id -gn "$u")"
```

Same owner-detection as podman, plus two more lookups: home directory (where dotfiles go) and `id -gn "$u"`, user's primary *group name* (needed so files owned by `user:group`). `if [ -z ] || [ ! -d ]` guards against missing or bogus home. (This the `SC2015` fix from earlier — written as proper `if` rather than `A && B || die`, which could fire `die` even when home was fine.)

```bash
	apt_install zsh zsh-syntax-highlighting zsh-autosuggestions tmux
```

Install shell, its two plugin packages (from apt — no downloads), and tmux.

```bash
	install_file "$home/.zshrc" 0644 "$u:$grp" <<'EOF'
... zsh config ...
EOF
```

Write `.zshrc` — note third argument `"$u:$grp"`, which makes file *user-owned*, not root-owned. Matters: zsh ignores config file owned by someone else. `'EOF'` quoted so `$` symbols in prompt string stay literal instead of expanding now. What each config line does (history, `compinit -C`, `vcs_info` git prompt, plugin sourcing order) explained in `shell.md`.

```bash
	install_file "$home/.tmux.conf" 0644 "$u:$grp" <<'EOF'
... tmux config ...
EOF
```

Same for `.tmux.conf`, also user-owned. Config choices (prefix `C-a`, `screen-256color`, `escape-time 10`, splits and pane movement) in `shell.md`.

```bash
	zsh_bin="$(command -v zsh || true)"
	if [ "${SHELL_NO_CHSH:-0}" = 1 ]; then
		warn "SHELL_NO_CHSH=1 — leaving login shell unchanged"
	elif [ -z "$zsh_bin" ]; then
		warn "zsh binary not found on PATH — not changing login shell"
	elif [ "$(getent passwd "$u" | cut -d: -f7)" = "$zsh_bin" ]; then
		ok "login shell already zsh for $u"
	else
		log "setting login shell to $zsh_bin for $u"
		run chsh -s "$zsh_bin" "$u"
	fi
```

Change login shell to zsh — carefully, via four-way `if`/`elif` ladder:

1. `command -v zsh` finds zsh's full path (`|| true` so not-found doesn't trip `set -e`).
2. Set `SHELL_NO_CHSH=1`: respect that, don't touch shell.
3. zsh somehow not on PATH: warn, skip.
4. Your shell (field 7 of passwd record) *already* zsh: nothing to do — this what makes re-running idempotent.
5. Otherwise, `chsh -s "$zsh_bin" "$u"` sets it. Takes effect next login, which final `ok` message reminds you.

### `install_rich` and the `SHELL_RICH` path

```bash
	local rich=0
	if [ "${SHELL_RICH:-0}" = 1 ]; then
		rich=1
	fi
	apt_install zsh zsh-syntax-highlighting zsh-autosuggestions tmux
	if [ "$rich" = 1 ]; then
		install_rich "$u"
	fi
```

`rich` = flag set to 1 only when you export `SHELL_RICH=1`. On: after apt packages, `install_rich` fetches two non-apt extras:

```bash
install_rich() {
	local u="$1"
	apt_install ca-certificates curl
	if command -v starship >/dev/null 2>&1; then
		ok "starship already installed"
	else
		run sh -c "curl -fsSL $STARSHIP_URL | sh -s -- -y -b /usr/local/bin"
	fi
	# shellcheck disable=SC2016
	if runuser -u "$u" -- sh -c 'command -v atuin >/dev/null 2>&1 || [ -x "$HOME/.atuin/bin/atuin" ]'; then
		ok "atuin already installed for $u"
	else
		run runuser -u "$u" -- sh -c "curl -fsSL $ATUIN_URL | sh -s -- --no-modify-path"
	fi
}
```

Each tool installed only if missing (idempotent). **starship** = single binary, downloaded and dropped into `/usr/local/bin` system-wide (`-y` = don't ask, `-b` = bin directory). **atuin** installed *as target user* into their `~/.atuin` (that's `runuser -u "$u"`), with `--no-modify-path` because our `~/.zshrc` already puts `~/.atuin/bin` on PATH. Atuin check deliberately single-quoted so `$HOME` expands inside *user's* shell, not root's — that what `# shellcheck disable=SC2016` acknowledges.

Build of `~/.zshrc` then becomes group command piped into `install_file`, appending guarded init block when `rich=1`:

```bash
	{
		cat <<'EOF'
... lean config ...
EOF
		if [ "$rich" = 1 ]; then
			cat <<'EOF'
export PATH="$HOME/.atuin/bin:$HOME/.local/bin:$PATH"
command -v starship >/dev/null && eval "$(starship init zsh)"
command -v atuin >/dev/null && eval "$(atuin init zsh)"
EOF
		fi
	} | install_file "$home/.zshrc" 0644 "$u:$grp"
```

`{ ... }` groups two possible chunks of output, pipes combined text into `install_file` (which reads content from stdin). `command -v X && eval` guards mean shell still starts even if starship or atuin missing — falls back to native prompt. See `shell.md` for offline-vs-rich trade-off.

### `configure_btop`

```bash
	if [ -e "$conf" ]; then
		ok "exists, left alone: $conf"
		return 0
	fi
```

Every other dotfile here is *managed*: script owns it, rewrites it, backs up what it replaced. btop's config is different, because **btop rewrites the file itself** when you quit it (it remembers which boxes you had open). Manage that and every re-run of `shell.sh` would see a "changed" file, back it up, and stamp its own version back — a pile of `.bak` files and your settings thrown away. So: write once, never again.

Contents tuned down:

```
update_ms = 2000
shown_boxes = "cpu mem net proc"
```

btop redraws ten times a second by default. Pretty on a desktop; on an A64 with btop parked in a tmux pane all day, that's real CPU spent drawing a picture nobody is looking at. Two seconds is plenty. GPU box left out of `shown_boxes` — SBC has no GPU worth watching.

---

## `setup/monitor.sh`

Shortest stage. Whole `main`:

```bash
	apt_install prometheus-node-exporter
	enable_now prometheus-node-exporter.service
	if [ "$DRY_RUN" != 1 ] && ! nft list table inet filter >/dev/null 2>&1; then
		warn "no nftables ruleset loaded — :9100 is exposed on every interface"
		warn "run setup/harden.sh, or firewall port 9100 yourself"
	fi
	ok "node_exporter listening on :9100"
```

Install metrics exporter, turn on. Then safety check: `nft list table inet filter` asks firewall "do you have ruleset from harden.sh loaded?" If that *fails* (`!` = "not") — meaning no firewall — warn loudly, because exporter listens on every network interface and only firewall keeps port 9100 private. Exporter isn't secured by itself; secured by wall around it. See `monitor.md`.

---

## `setup/backup.sh`

restic backups. Three helper functions plus `main`.

### `create_if_absent` (lines 35–52)

```bash
create_if_absent() {
	local dest="$1" mode="$2" tmp
	if [ -e "$dest" ]; then
		ok "exists, left alone: $dest"
		cat >/dev/null
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would create $dest (mode $mode)"
		cat >/dev/null
		return 0
	fi
	tmp="$(mktemp)"
	cat >"$tmp"
	install -D -m "$mode" "$tmp" "$dest"
	rm -f "$tmp"
	ok "created $dest"
}
```

Cousin of `install_file`, one crucial difference: **never overwrites**. These files hold secrets (backup password) and your own edits (repo location), so once they exist we leave them completely alone. Destination exists: say so and stop — but note `cat >/dev/null`: caller still piping content in via heredoc, and if we didn't *consume* that input script would misbehave, so we read it and throw away (`/dev/null` = void). Dry-run likewise previews and discards. Only when file genuinely absent do we create it.

### `write_config` (lines 54–102)

```bash
	run install -d -m 0700 "$ETC"
```

Create `/etc/restic` as directory (`-d`) with mode `0700` (only root can even look inside — holds encryption key).

```bash
	create_if_absent "$ENV_FILE" 0600 <<'EOF'
...
RESTIC_REPOSITORY=
RESTIC_PASSWORD_FILE=/etc/restic/password
RESTIC_CACHE_DIR=/var/cache/restic
EOF
```

Create env file (mode `0600` = only root can read/write) with `RESTIC_REPOSITORY` deliberately *blank* — you fill in. Comments show example destinations (NAS over SFTP, S3 bucket, USB path).

```bash
	if [ ! -e "$PW_FILE" ] && [ "$DRY_RUN" != 1 ]; then
		head -c 32 /dev/urandom | base64 | create_if_absent "$PW_FILE" 0600
		cat >&2 <<EOF
  ... IMPORTANT: this key is the ONLY way to decrypt your backups ...
EOF
	else
		create_if_absent "$PW_FILE" 0600 </dev/null
	fi
```

Generate encryption key, once. `head -c 32 /dev/urandom` reads 32 random bytes from kernel's randomness source; `base64` turns them into safe text characters; that gets piped into `create_if_absent` as file content. Then big warning prints — **lose this key and your backups are permanently unreadable.** `else` branch (used during dry-run, or if key already exists) calls `create_if_absent` with `</dev/null` — empty input — because we don't want real key generated during rehearsal.

```bash
	create_if_absent "$ETC/paths" 0644 <<'EOF'
/etc
/home
EOF
	create_if_absent "$ETC/excludes" 0644 <<'EOF'
**/.cache
**/node_modules
**/.git
/home/*/.local/share/containers
/var/cache
EOF
```

Two plain lists: what to back up (`/etc` config, `/home` your files) and what to skip (caches, `node_modules`, git internals, container storage — bulky stuff you can regenerate). `**` = "any depth of folders."

### `write_units` (lines 104–146)

```bash
	install_file /etc/systemd/system/restic-backup.service <<'EOF'
[Unit]
Description=restic backup
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
CacheDirectory=restic
Nice=19
IOSchedulingClass=idle
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only
ExecStartPre=-/usr/bin/restic init
ExecStart=/usr/bin/restic backup --files-from /etc/restic/paths --exclude-file /etc/restic/excludes
ExecStartPost=/usr/bin/restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
EOF
```

Backup *job* itself, as systemd service. Line by line:

- `Wants=/After=network-online.target` — don't start until network up (can't reach remote backup repo without it).
- `Type=oneshot` — runs, finishes, exits (not service that stays running).
- `EnvironmentFile=/etc/restic/env` — load repo location and credentials.
- `CacheDirectory=restic` — systemd provides `/var/cache/restic` automatically.
- `Nice=19` and `IOSchedulingClass=idle` — run at *lowest* CPU and disk priority, so backup never bogs down one-core SBC.
- `PrivateTmp`, `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only` — sandboxing. Job gets private temp folder, can't gain new privileges, sees most of filesystem as read-only, can only *read* home directories (backing them up, not changing them). `full` rather than `strict` so repo on `/mnt` or `/srv` still works — see `backup.md`.
- `ExecStartPre=-/usr/bin/restic init` — before backing up, create repository. Leading `-` = "if this fails, carry on anyway" — after first time, "init" correctly fails ("already exists") and we don't want that to abort backup.
- `ExecStart=... restic backup ...` — actual backup, reading paths and excludes files.
- `ExecStartPost=... restic forget --prune ...` — afterward, delete old snapshots beyond retention window (7 daily, 4 weekly, 6 monthly), reclaim space.

```bash
	install_file /etc/systemd/system/restic-backup.timer <<'EOF'
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
	run systemctl daemon-reload
```

*Schedule*. `OnCalendar=daily` = run once a day. `RandomizedDelaySec=1h` = jitter start by up to hour (so many machines don't all hammer backup server at midnight). `Persistent=true` = box off at scheduled time, run backup at next boot. `WantedBy=timers.target` = start timer on boot. `systemctl daemon-reload` makes systemd re-read these two new unit files.

### `repo_configured` (lines 150–153)

```bash
repo_configured() {
	[ -r "$ENV_FILE" ] || return 1
	grep -qE '^[[:space:]]*RESTIC_REPOSITORY=[^[:space:]]' "$ENV_FILE"
}
```

Have you set backup destination yet? Only if env file readable *and* has `RESTIC_REPOSITORY=` line with something non-blank after `=` (`[^[:space:]]` = "non-whitespace character"). Notice it *greps* file rather than *sourcing* (running) it — config file you edit by hand shouldn't be executed; stray backtick could run command. Searching is safe.

### `main` (lines 155–172)

```bash
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] timer left untouched"
	elif repo_configured; then
		enable_now restic-backup.timer
		ok "backup timer enabled — next run: $(...)"
	else
		warn "RESTIC_REPOSITORY is empty in $ENV_FILE — timer NOT enabled"
		warn "set it, then re-run: sudo setup/backup.sh"
	fi
```

Install restic, write config and units, then decide about timer. Rehearsal: leave alone. Destination configured: enable daily timer. Not: *deliberately* leave disabled and tell you why — backup job pointing at nothing looks healthy while protecting nothing, worse than no job at all. Re-run once destination set and it flips on.

---

## `setup/bootstrap.sh`

Conductor that runs all seven stages.

```bash
STAGES=(base harden tailscale podman shell monitor backup)
```

Ordered list. Order load-bearing (see header comment and each stage's doc): `harden` must set firewall rule welcoming Tailscale *before* `tailscale` arrives, and `monitor` only safe because `harden` already ran.

### `skipped` (lines 33–41)

```bash
skipped() {
	local s
	for s in ${SKIP:-}; do
		if [ "$s" = "$1" ]; then
			return 0
		fi
	done
	return 1
}
```

Lets you leave stages out with `SKIP="tailscale monitor"`. Walks words in `SKIP`, returns success (0 = "yes, skip it") if stage name matches. `${SKIP:-}` = "value of SKIP, or empty if unset" — `:-` keeps `set -u` from complaining about undefined variable.

### `main` (lines 43–73)

```bash
	local stage args=()
	if [ "$DRY_RUN" = 1 ]; then
		args+=(--dry-run)
	fi
	for stage in "${STAGES[@]}"; do
		if skipped "$stage"; then
			warn "skipping $stage"
			continue
		fi
		log "──── $stage ────"
		"$SELF_DIR/$stage.sh" ${args[@]+"${args[@]}"}
	done
```

Build argument list: dry-run, add `--dry-run` so it passes down to every stage. Then loop stages in order: skip ones you asked to skip (`continue` jumps to next loop iteration), print header, run stage script. `"$SELF_DIR/$stage.sh"` = full path to, e.g., `setup/harden.sh`. `${args[@]+"${args[@]}"}` incantation = "expand args list if it has anything in it, otherwise expand to nothing" — safe way to pass array that might be empty without tripping `set -u`.

```bash
	ok "bootstrap complete"
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi
	cat >&2 <<'EOF'
Next steps:
  1. sudo tailscale up ...
  ...
EOF
```

Announce completion. Rehearsal: stop here. Real run: print manual follow-ups scripts *deliberately* don't do for you: log in to Tailscale, copy restic key somewhere safe, set backup destination, finish SSH lockdown once key in place. These steps need human decision or browser — automation takes you right up to them, no further.

---

## `setup/wizard.sh` — the interactive front end

`bootstrap.sh` is for machines. This one is for people: it asks, then does. Same stage scripts underneath — the wizard just fills in the environment variables you would otherwise have had to remember.

### Asking

```bash
ask_yn() {
	local q="$1" def="$2" reply hint='[y/N]'
	if [ "$def" = y ]; then hint='[Y/n]'; fi
	printf '  %s %s ' "$q" "$hint" >&2
	read -r reply
	if [ -z "$reply" ]; then reply="$def"; fi
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}
```

Question printed to **stderr**, answer read from the terminal. Why stderr? Same reason every log line in this repo goes there: stdout stays clean, so you could pipe the script's output somewhere without the questions ending up in the pipe. Empty answer = the default (the capital letter in `[Y/n]`). Anything that isn't clearly yes counts as no.

`ask_val` is the same idea for text (`[default]` shown in brackets). `ask_secret` uses `read -rs` — the `s` means "don't echo" — so a Tailscale auth key never appears on screen or in the scrollback of a shared terminal. Addresses and paths are echoed; they aren't secrets.

### Collect, then show, then do

`interview` fills in variables (`WANT`, `APPS_WANTED`, `TS_KEY`, `RESTIC_REPO`…) and runs *nothing*. `summary` prints the whole plan. Only after you confirm does `apply` run. Say no and the script `die`s with "aborted — nothing was changed", which is literally true: at that point not one file has been touched.

### Seeding config before the stage that reads it

```bash
	if [ -n "$RESTIC_REPO" ]; then
		preseed /etc/restic/env 0600 <<EOF
RESTIC_REPOSITORY=$RESTIC_REPO
…
EOF
	fi
```

This is the trick that makes the wizard worth having. `backup.sh` refuses to enable its timer while the repository is empty; `apps.sh` refuses to start dfs while its public address is empty. Normally that means: run script, edit file, run script again. The wizard asked you up front, so it writes the config file *first* — and the stage then finds a configured box and turns the thing on the first time.

`preseed` refuses to overwrite an existing file, warning that your answer wasn't used. That file could be pointing at a *live* backup repository; silently replacing it is how backups get lost. Config = the operator's, always.

### Running the children

```bash
	export SHELL_RICH="$RICH"
	…
	for s in ${WANT[@]+"${WANT[@]}"}; do
		"$SELF_DIR/$s.sh" ${args[@]+"${args[@]}"}
	done
```

Plain `export` is enough here — the wizard already re-exec'd itself under sudo, so the children start as root and inherit the environment normally. (The `SUDO_KEEP` list in `common.sh` exists for the *other* direction: a script you launch as a normal user, which then jumps through sudo and would otherwise lose its variables.)

### The guard it deliberately doesn't disarm

```bash
	# Deliberately NOT passing XFCE_YES: the remover asks for itself and refuses
	# inside a graphical session.
	if [ "$REMOVE_XFCE" = 1 ]; then
		"$SELF_DIR/remove-xfce.sh" ${args[@]+"${args[@]}"}
	fi
```

You said yes in the plan. The remover asks *again* anyway, and still refuses to run from inside a graphical session. Deliberate: one `y` buried in a list of twelve questions shouldn't disarm both safety guards on the only irreversible thing in the repo. Pressing `y` twice is cheap. Purging a desktop you meant to keep is not.

### No terminal, no wizard

```bash
	[ -t 0 ] || die "wizard needs a terminal — for unattended runs use bootstrap.sh"
```

`-t 0` = "is stdin a terminal?" Run from cron with no keyboard, every `read` returns empty instantly, every question takes its default, and the box installs whatever the defaults happen to be. Refuse instead. Unattended has its own front door: `bootstrap.sh` plus environment variables.

---

## `setup/apps.sh` — the optional apps (not in bootstrap)

Installs self-hosted apps you asked for. Today one: **dfs** (steves-domainless-filehosting) — file host with accounts, web UI, share links, everything encrypted on disk. Written in Go, stdlib only, ends up as one static binary.

Loop at bottom decides what runs:

```bash
APPS="${APPS:-dfs}"
...
	for app in $APPS; do
		case "$app" in
			dfs) log "──── dfs ────"; install_dfs ;;
			*)   die "unknown app: $app" ;;
		esac
	done
```

`APPS` = space-separated wish list, `dfs` when you say nothing. Unknown name = `die`, not silent skip. Adding a second app later = one more `case` arm.

### `dfs_sync_source`

```bash
	if [ -d "$DFS_SRC/.git" ]; then
		run git -C "$DFS_SRC" fetch --depth 1 origin "$DFS_REF"
		run git -C "$DFS_SRC" checkout -q FETCH_HEAD
	else
		run git clone --depth 1 --branch "$DFS_REF" "$DFS_REPO" "$DFS_SRC"
	fi
	git -C "$DFS_SRC" rev-parse HEAD 2>/dev/null || true
```

First run: clone. Later runs: fetch newest commit, jump to it. `--depth 1` = "only the newest commit, not ten years of history" — smaller download, less SD card burned. `git -C DIR` = "pretend you're in DIR" (no `cd`, so nothing leaks to the rest of the script). Last line prints the commit hash it landed on; that hash is the function's *return value*. `|| true` because on a dry run nothing was cloned and asking for the hash of an empty folder is an error we don't care about.

### `dfs_build`

```bash
	if [ -x "$DFS_BIN" ] && [ -f "$DFS_STAMP" ] && [ "$(cat "$DFS_STAMP")" = "$commit" ] && [ -n "$commit" ]; then
		ok "dfs already built at $commit"
		return 0
	fi
	run env GOTOOLCHAIN=auto GOCACHE=/var/cache/go-build GOPATH=/var/lib/go HOME=/root \
		go -C "$DFS_SRC" build -p 2 -trimpath -ldflags '-s -w' -o "$DFS_BIN" .
	...
	printf '%s\n' "$commit" >"$DFS_STAMP"
```

Idempotence trick: after each build, write the commit hash into a stamp file. Next run, if binary exists *and* stamp matches the commit we just checked out, skip the build. Nothing changed = nothing to compile, and compiling Go on a Pinebook is minutes, not seconds.

Three build knobs earn their place:

- **`GOTOOLCHAIN=auto`** — dfs's `go.mod` asks for a newer Go than Debian ships. `auto` lets Go download exactly the toolchain it needs. Without it: hard error, "requires go >= 1.26".
- **`-p 2`** — compile at most 2 files at once. Default = one job per CPU core, and four parallel Go compilers on a 2 GB board runs it out of memory.
- **`-trimpath -ldflags '-s -w'`** — strip build paths and debug symbols. Smaller binary, and no `/usr/local/src/...` strings baked in.

`GOCACHE` / `GOPATH` / `HOME` pinned because we're root under sudo, and Go otherwise scatters caches wherever `HOME` happens to point.

### `dfs_account`, `dfs_config`, `dfs_unit`

```bash
	run useradd --system --home-dir "$DFS_DATA" --shell /usr/sbin/nologin dfs
	run install -d -m 0700 -o dfs -g dfs "$DFS_DATA"
```

Its own system user, no login shell — a file host that gets broken into shouldn't hand over a shell. Data dir `0700` (owner only): it holds `master.key` plus every user's encrypted file. Nobody else on the box gets to read it.

`dfs_config` reuses backup.sh's **`create_if_absent`** — writes `/etc/dfs/env` once, never touches it again, because that file holds *your* decisions. `dfs_configured` then *greps* it rather than sourcing it (same reasoning as restic: sourcing runs whatever ended up in the file).

The unit is where the sandboxing lives:

```
ProtectSystem=strict     # whole filesystem read-only …
StateDirectory=dfs       # … except /var/lib/dfs
ProtectHome=yes          # /home invisible
RestrictAddressFamilies=AF_INET AF_INET6   # TCP/IP only, no unix/netlink tricks
MemoryMax=512M           # can't eat the whole board
```

`ExecStart=... --public ${DFS_PUBLIC}` reads that variable out of the env file at start time.

**Why the service stays disabled until `DFS_PUBLIC` is set:** it's the host:port users type, *and* the name baked into the self-signed TLS certificate. Empty = a cert for nobody, a service reachable at no address. Same philosophy as restic's empty repository: a thing that looks green while doing nothing is worse than a thing that's honestly off.

Last check calls `firewall_note`, which warns if no ruleset is loaded — because with harden.sh's ruleset, no app port is opened, so an app is reachable over `tailscale0` only. That's deliberate: a file host on the open internet should be a decision, not an accident.

### `install_navidrome` and friends

Navidrome = music server: web player, plus the Subsonic API every phone music app speaks. Unlike dfs it is **not** built here — upstream ships a `.deb`, and compiling it would drag Node in to build the bundled web UI. On a 2 GB board: no.

```bash
nd_asset_arch() {
	case "$(arch)" in
		amd64) printf 'amd64' ;;
		arm64) printf 'arm64' ;;
		armhf) printf 'armv7' ;;
		i386)  printf '386' ;;
		*)     die "no navidrome release for architecture $(arch)" ;;
	esac
}
```

Debian calls a 32-bit ARM board `armhf`; the release file calls it `armv7`. Translation table, and `die` on anything with no release — better than downloading a 404 page and trying to install it.

```bash
nd_resolve_version() {
	if [ "$ND_VERSION" != latest ]; then
		printf '%s' "$ND_VERSION"
		return 0
	fi
	curl -fsSL "https://api.github.com/repos/$ND_REPO/releases/latest" |
		sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
		head -n1
}
```

"Latest" is resolved to a real tag **once**, then that tag is used for the version check, the download and the checksum. Ask twice and you could compare against 0.63.2 while downloading 0.63.3 if upstream publishes mid-run. `sed -n 's/…/\1/p'` = "find the `tag_name` line, keep only what's inside the quotes." Pin a version instead with `NAVIDROME_VERSION=v0.63.2`.

```bash
	run curl -fsSL --retry 3 -o "$dir/$deb" "$base/$deb"
	run curl -fsSL --retry 3 -o "$dir/navidrome_checksums.txt" "$base/navidrome_checksums.txt"
	( cd "$dir" && grep -F " $deb" navidrome_checksums.txt | sha256sum -c - ) ||
		die "checksum mismatch for $deb — refusing to install"
```

Download the package, download the release's list of fingerprints, check ours against it. `sha256sum` boils a file down to one 64-character fingerprint; change one byte anywhere and the fingerprint changes completely. `grep -F " $deb"` picks the one line for our file (`-F` = "treat this as plain text, not a pattern"), `sha256sum -c -` says OK or fails. Mismatch = `die`, no install. You are about to run this thing as a service — check it came from where you think.

(The checksum file is called `navidrome_checksums.txt`, not `checksums.txt`. Guessing the obvious name gives a 404. Asking the API for the real asset names is how that got found.)

```bash
	if [ "$(nd_installed_version)" = "$ver" ]; then
		ok "navidrome $ver already installed"
	else
		…
		run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$deb"
	fi
```

Idempotence again: dpkg already knows what version is installed, so ask it and skip the whole download when it matches. `apt-get install ./file.deb`, **not** `dpkg -i`: apt pulls the package's dependency (`ffmpeg`, for transcoding) along with it; `dpkg` would install a half-broken package and complain.

`nd_config` writes `/etc/navidrome/navidrome.toml` and creates the music folder:

```toml
MusicFolder = "/srv/music"
ScanSchedule = "@every 24h"
TranscodingCacheSize = "50MB"
ImageCacheSize = "100MB"
```

Caches are tiny on purpose: they land on the SD card, and SD cards wear out from being written to. One scan a day for the same reason (Navidrome also notices files as they appear).

The music folder is created owned by **you**, not by the service — `install -d -m 0755 -o "$owner"`. The library is the operator's; navidrome only ever reads it.

Then `enable_now navidrome.service` (the `.deb` brought the unit with it), `firewall_note navidrome`, and a loud warning: **whoever loads the web page first becomes the admin.** Navidrome has no password until someone sets one. Claim it immediately.

## `setup/remove-xfce.sh` — the uninstaller

Rips a desktop off a box meant to be headless. Deliberately **not** in bootstrap: purging is not reversible, so it never happens automatically.

### Finding what to purge

```bash
PATTERNS=('xfce4*' 'xfdesktop4*' 'xfwm4*' … 'lightdm*' 'xscreensaver*')

matching_packages() {
	while read -r pkg status; do
		[ "$status" = installed ] || continue
		for pat in "$@"; do
			case "$pkg" in
				$pat) printf '%s\n' "$pkg"; break ;;
			esac
		done
	done < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null)
}
```

Ask dpkg for every package plus its state, keep the `installed` ones, print the names matching a pattern. `case "$pkg" in $pat)` — `$pat` **unquoted on purpose**, so `xfce4*` behaves as a wildcard instead of a literal name. `break` stops after the first pattern matches, so a package is never listed twice.

Why patterns and not one big fixed list? Names differ between Debian, Ubuntu and Armbian images. Match by shape, and this works on all of them. Only *top-level* desktop packages are listed: the pile of `libxfce4…` libraries underneath is left to `apt-get autoremove --purge`, which sweeps them once nothing needs them.

### The two guards

```bash
	if [ "$DRY_RUN" != 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "${XFCE_YES:-0}" != 1 ]; then
		die "a graphical session is active — run this from a TTY or over SSH (or set XFCE_YES=1)"
	fi
```

`DISPLAY` set = you're inside a graphical session — quite possibly an XFCE terminal, i.e. the thing about to be purged out from under you. Refuse. A *dry run* changes nothing, so previewing from the desktop is fine.

```bash
	printf 'Purge the %s packages above? [y/N] ' "$1" >&2
	read -r reply
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) die "aborted" ;;
	esac
```

The one place in this repo that *asks*. Everything else here is safe to re-run; this deletes things. Anything that isn't a clear yes = abort. `[ ! -t 0 ]` (no keyboard attached, e.g. run from cron) also aborts unless you set `XFCE_YES=1` — no unattended desktop deletion.

### Afterwards

```bash
	if [ "$(systemctl get-default)" = graphical.target ]; then
		run systemctl set-default multi-user.target
	fi
```

The boot target was "start the graphical login." The graphical login is gone. Leave it and boot hangs waiting for a desktop that no longer exists — so switch it to `multi-user.target` (console). Final `warn` reminds you the leftovers in *your home folder* (`~/.config/xfce4`) are yours to delete: the script won't reach into a user's files.

---

That's every line that does something. Recurring themes, one more time: **validate before you apply** (sshd, nftables), **check before you change** (idempotence), **back up before you overwrite** (reversibility), and **fail loudly rather than pretend** (guards that `die`). Those four ideas = whole personality of project.