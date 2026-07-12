# Line-by-line, explained like you're 11

This is the deep version. Every function, every operation, in plain language. If
you want the short "what does this stage do," read the per-stage docs instead
(`base.md`, `harden.md`, …). This file is for "what does *this line* do, and why."

It's long. Use the table of contents.

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

Every `setup/*.sh` file starts with the same four lines. Learn them once:

```bash
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
```

**`#!/usr/bin/env bash`** — the "shebang." When you run the file, the system reads
this first line to know *what program* should interpret it. `/usr/bin/env bash`
means "find bash on the PATH and use it." Using `env` instead of a hard-coded
`/bin/bash` makes it portable to systems where bash lives elsewhere.

**`if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi`** — a self-defence
guard. If someone starts the script with `sh setup/foo.sh` instead of
`./setup/foo.sh`, the `sh` order overrides the shebang and the script runs under
dash, which can't do `pipefail` or the bash tricks below. `$BASH_VERSION` is only
set when bash is running, so `[ -z ... ]` ("is it empty?") detects dash and
`exec bash "$0" "$@"` restarts the same script under bash. The line itself is
plain POSIX so dash can read it. Written *before* `set -o pipefail` on purpose —
it has to run before the line that would otherwise crash.

**`set -euo pipefail`** — four safety switches flipped on at once. This is the
single most important line for correctness:

- `-e` — **exit on error.** If any command fails, stop the whole script right
  there. No blundering onward after something broke.
- `-u` — **error on undefined variables.** Type `$USERNAM` when you meant
  `$USERNAME`, and instead of silently using an empty string, the script stops.
  Catches typos.
- `-o pipefail` — in a pipe like `a | b`, normally only `b`'s success counts. With
  this, if `a` fails the whole pipe fails. Without it, failures hide in the
  middle of pipes.
- (`-o` is just the switch that turns on the named option `pipefail`.)

The catch: `-e` is what caused the nastiest bug in this project — see
`require_root` below.

**`# shellcheck source=../lib/common.sh`** — a note to *shellcheck*, the linter.
Not run by bash at all (it's a comment). It tells the linter "the next line pulls
in this other file, go read it so you understand these functions." Keeps the
lint clean.

**`. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"`** — this loads the
shared toolbox. Read it inside-out:

- `$0` is the path used to run this script (e.g. `./setup/base.sh`).
- `readlink -f "$0"` turns that into a full, real path with all symlinks
  resolved (e.g. `/home/steve/steves-sbc-setup/setup/base.sh`).
- `dirname ...` strips the filename, leaving the folder
  (`/home/steve/steves-sbc-setup/setup`).
- `/../lib/common.sh` steps up one folder and into `lib/common.sh`.
- The leading `.` (a dot, same as `source`) means "run that file *in this
  shell*," so all its functions and variables become available here.

The whole dance exists so the script finds its toolbox no matter what folder you
run it from.

And every script *ends* with the same three lines:

```bash
parse_common_args "$@"
require_root "$@"
main
```

Parse the flags, become root if needed, then do the work. `"$@"` means "all the
arguments you were given," passed along untouched.

---

## `lib/common.sh` — the toolbox

Not run on its own — it's the shared box of tools every stage borrows from.

```bash
set -euo pipefail
```
Same safety switches, so the tools are strict too.

### Finding its own location (lines 8–11)

```bash
SELF="$(readlink -f "${BASH_SOURCE[-1]}")"
SELF_DIR="$(dirname "$SELF")"
REPO_DIR="$(dirname "$SELF_DIR")"
export SELF SELF_DIR REPO_DIR
```

`${BASH_SOURCE[-1]}` is a clever bit. `BASH_SOURCE` is a list of files in the
current call chain; `[-1]` is the *last* one — the original script you actually
ran (like `base.sh`), **not** this library. So `SELF` becomes the full path of
the entry script, `SELF_DIR` its folder (`setup/`), and `REPO_DIR` the folder
above that (the repo root). `export` makes these visible to any programs the
script launches. `require_root` uses `SELF` to re-launch the *right* script under
sudo.

### Colors (lines 14–18)

```bash
if [ -t 2 ]; then
	C_R=$'\e[31m' C_G=$'\e[32m' ...
else
	C_R='' C_G='' ...
fi
```

`[ -t 2 ]` asks "is 'standard error' a real terminal?" (2 is the number for
stderr). If yes, set variables to the magic codes that make text red/green/etc.
If the output is being piped to a file or another program, set them to empty
strings — no one wants `\e[31m` gibberish in a log file. `$'\e[31m'` is bash's
way of writing an escape character followed by the color code.

### The four message functions (lines 19–22)

```bash
log()  { printf '%s==>%s %s\n'  "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
```

Four ways to print a message. `log` = blue "what I'm doing now," `ok` = green
success, `warn` = yellow caution, `die` = red error *and then quit* (`exit 1`
means "stop with a failure code"). `%s` is a placeholder printf fills with the
arguments; `$*` is "all the words passed to this function"; `$C_0` resets the
color back to normal. `>&2` sends the message to stderr — the "messages" channel,
kept separate from actual output so the two don't get mixed.

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

`DRY_RUN="${DRY_RUN:-0}"` means "if DRY_RUN was already set, keep it; otherwise
make it 0 (off)." Then `run` is the heart of dry-run mode: hand it a command, and
if dry-run is on it just *prints* the command in yellow; if off, `"$@"` actually
*runs* it. So every dangerous action wrapped in `run` becomes a harmless preview
during a rehearsal.

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

Walk through each argument. `--dry-run` flips on rehearsal mode. `-h` or `--help`
prints the usage text (each script defines its own `usage`) and quits happily
(`exit 0`). Anything else (`*` = "any other value") is a typo, so `die` with a
helpful message. `local a` keeps the loop variable from leaking out and clobbering
something else.

### Becoming root (lines 52–59)

```bash
require_root() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	command -v sudo >/dev/null 2>&1 || die "root required and sudo not found"
	log "re-executing under sudo…"
	exec sudo DRY_RUN="$DRY_RUN" "$SELF" "$@"
}
```

`id -u` prints your user-number; 0 means root. So "if I'm already root, we're
done." Otherwise: `command -v sudo` checks sudo exists (the `>/dev/null 2>&1`
throws away its output — we only care whether it *succeeds*), and if not, `die`.
Then `exec sudo ... "$SELF" "$@"` **replaces** the current script with a new one
running as root — same script (`$SELF`), same arguments (`$@`), with `DRY_RUN`
passed along explicitly so rehearsal mode survives the jump. `exec` means "become
that new process," so nothing after this line runs in the old one.

**Why the long `if` instead of `[ "$(id -u)" -eq 0 ] && return 0`?** This is *the*
bug from earlier. Under `set -e`, if you write `test && return 0` and the test is
*false*, the whole `&& ` line is considered a failed command — and `-e` kills the
script on the spot. So the short version quietly *exited* instead of continuing to
the sudo line, meaning the script never actually became root. The verbose
`if ...; then return; fi` form avoids the trap. This pattern is used everywhere in
the repo for exactly this reason.

### Platform guard (lines 62–65)

```bash
require_apt_systemd() {
	command -v apt-get >/dev/null 2>&1 || die "unsupported: needs an apt distro ..."
	[ -d /run/systemd/system ] || die "unsupported: systemd is required"
}
```

Refuse to run somewhere these scripts don't fit. `command -v apt-get` checks this
is a Debian-family system. `[ -d /run/systemd/system ]` checks systemd is the init
system (that folder only exists when systemd is running). Either missing → `die`
with a clear reason instead of failing weirdly ten steps later.

### Two tiny helpers (lines 68–71)

```bash
arch() { dpkg --print-architecture; }
target_user() { printf '%s' "${SUDO_USER:-${TARGET_USER:-}}"; }
```

`arch` prints `arm64` or `amd64`. `target_user` answers "who is the human that
owns this box?" — since scripts run as root, it looks at `SUDO_USER` (the account
that *called* sudo), falling back to `TARGET_USER` if you set it, falling back to
empty. The `${A:-${B:-}}` nesting is "use A, or if empty use B, or if that's empty
use nothing."

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

`apt-get update` (refreshing the list of available packages) is slow, and several
stages might want it. This runs it *at most once* per script: `_APT_UPDATED` is a
flag; `[ -n ... ]` means "is it non-empty?" If already set, skip. Otherwise update
and set the flag. (Same verbose-`if` guard, same `set -e` reason.)

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

Install packages, but *only the missing ones* — that's what makes re-runs fast
and quiet. `miss=()` is an empty list. For each requested package, `dpkg -s`
checks if it's installed; if not (`||`), add it to `miss`. `${#miss[@]}` is "how
many items in miss"; if zero, everything's already there, say so and return.
Otherwise update the package list, then install. `DEBIAN_FRONTEND=noninteractive`
tells apt "don't stop to ask me questions" (vital for an unattended script).
`-y` = "yes to prompts." `--no-install-recommends` = "install *only* what I asked
for, not the pile of optional extras" — keeps a lean box lean.

### The idempotent file writer (lines 100–126)

```bash
install_file() {
	local dest="$1" mode="${2:-0644}" owner="${3:-}" tmp
	tmp="$(mktemp)"
	cat >"$tmp"
```

The workhorse. Takes a destination path, an optional permission mode (default
`0644` = owner-writes, everyone-reads), and an optional owner. `mktemp` makes a
safe temporary file; `cat >"$tmp"` pours the content (piped in from the calling
script via `<<EOF`) into it.

```bash
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		ok "unchanged: $dest"
		return 0
	fi
```

**The idempotent bit.** If the destination already exists *and* `cmp -s` (a silent
byte-by-byte compare) says the new content is identical, there's nothing to do —
delete the temp file, report "unchanged," done. Re-running changes nothing.

```bash
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would write $dest (mode $mode${owner:+, owner $owner}):"
		sed 's/^/      /' "$tmp" >&2
		rm -f "$tmp"
		return 0
	fi
```

Rehearsal mode: don't write, just show what *would* be written. `sed 's/^/      /'`
adds six spaces to the start of every line so the preview is clearly indented.
`${owner:+, owner $owner}` means "if owner is set, print `, owner X`; otherwise
print nothing" — a neat way to only mention ownership when it matters.

```bash
	if [ -f "$dest" ]; then
		cp -a "$dest" "$dest.bak.$(date +%s)"
		warn "backed up existing $dest"
	fi
```

**The reversible bit.** If we're about to overwrite a real file, first copy it to
`<file>.bak.<number>`, where `$(date +%s)` is the current time in seconds (a
unique-ish stamp). `cp -a` preserves the original's permissions and ownership.
Nothing is ever destroyed without a copy.

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

Finally, place the file. `install -D` copies it and creates any missing parent
folders, `-m` sets the permission mode. If an owner was given, `-o` sets the user
and `-g` the group: `${owner%%:*}` chops off everything from the first `:` onward
(leaving the user), and `${owner##*:}` chops off everything up to the last `:`
(leaving the group). So `steve:steve` becomes `-o steve -g steve`. Clean up the
temp file, report success.

### One-liner (line 129)

```bash
enable_now() { run systemctl enable --now "$1"; }
```

"Turn a service on now *and* set it to start on every boot." `enable` = start at
boot, `--now` = also start it this instant. Wrapped in `run` so it obeys
dry-run.

---

## `setup/base.sh`

Turns the utilities on. After the shared header:

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

Install `zram-tools`, then write its config. The `<<'EOF' ... EOF` is a
"heredoc" — everything between the markers is fed as input to `install_file`,
which becomes the file's content. The quotes around `'EOF'` mean "don't do any
variable substitution in here, take it literally." Settings: `ALGO=zstd` (the
compression method — fast and effective), `PERCENT=50` (use half of RAM for
compressed swap), `PRIORITY=100` (prefer this swap over any other). Then turn the
service on. See `base.md` for *why* compressed swap is the right call on a 2 GB
board.

### `setup_auto_upgrades` (lines 38–48)

```bash
	install_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Install `unattended-upgrades` and switch it on via this config. The three lines
mean: refresh the package list daily (`"1"` = every 1 day), apply unattended
upgrades daily, and clean out old downloaded packages every 7 days. By default
`unattended-upgrades` only touches the *security* archive, so this stays to
security patches — nothing that reboots you into a surprise new kernel.

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

Check the platform, announce the architecture, install the essentials
(`ca-certificates` = the list of trustable web certificate authorities, `curl` =
download tool, `gnupg` = signature verification, `chrony` = the clock fixer), turn
the clock service on *first* (so later HTTPS downloads don't fail on a 1970 date —
see `base.md`), then the two helper functions. Done.

---

## `setup/harden.sh`

Locks the doors. Three functions for three layers.

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

Answers "does anyone have a login key installed?" — the guard that stops you
locking yourself out. It checks two accounts: `root` and the box's owner. For
each: `[ -n "$u" ] || continue` skips empty names (if there's no owner set).
`getent passwd "$u" | cut -d: -f6` looks up that user's record and grabs field 6,
the home directory (`getent` reads the account database; `cut -d: -f6` splits on
`:` and takes the 6th piece). Then it looks at `~/.ssh/authorized_keys`:
`[ -s "$f" ]` = "exists and is non-empty," and `grep -qE '^[^#[:space:]]'` = "has
at least one line that isn't blank or a comment" (a real key). If so, `return 0`
(success — "yes, a key exists"). If neither account has one, `return 1` (failure —
"no keys"). In shell, 0 = true/success, non-zero = false.

### `harden_ssh` (lines 44–89)

```bash
	apt_install openssh-server
	if [ "$DRY_RUN" = 1 ] && [ ! -f /etc/ssh/sshd_config ]; then
		warn "[dry] openssh-server not installed — skipping sshd checks"
		return 0
	fi
```

Make sure the SSH server is installed (this stage owns its own dependency so it
works standalone). The `if` handles a rehearsal on a box where SSH isn't installed
yet: during dry-run nothing actually got installed, so there's no config to check —
skip gracefully instead of erroring.

```bash
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
		die "/etc/ssh/sshd_config lacks an Include for sshd_config.d — ..."
	fi
```

Our hardening goes into a *drop-in* file in a `sshd_config.d/` folder. But SSH
only reads that folder if the main config says to, via an `Include` line. This
greps for that line; if it's missing, our file would be silently ignored — a
dangerous illusion of security — so we `die` and tell you to fix it. Better to
fail loudly than to *think* you're hardened when you're not.

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

The safety decision. Default to leaving passwords *on* (`pw_auth='yes'`). Only
switch them off if `has_ssh_key` says a key exists **or** you've forced it with
`FORCE_SSH_KEYONLY=1`. No key and no force? Warn and leave passwords on. This is
what makes it impossible to strand yourself.

```bash
	install_file /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<EOF
...
PasswordAuthentication $pw_auth
...
EOF
```

Write the drop-in. Note this heredoc is `<<EOF` *without* quotes, so `$pw_auth`
and `$note` get substituted in with the values chosen above. The settings:
`PermitRootLogin no` (no direct root), `PasswordAuthentication $pw_auth` (on or off
per the decision), `KbdInteractiveAuthentication no` and `PermitEmptyPasswords no`
(close other password-ish doors), `MaxAuthTries 3` (three guesses then
disconnect), `LoginGraceTime 20` (20 seconds to log in or you're dropped),
`X11Forwarding no` (no graphical forwarding — pointless on a headless box, and one
less attack surface).

```bash
	if [ "$DRY_RUN" != 1 ]; then
		sshd -t || die "sshd config validation failed — not reloading"
	fi
	enable_now ssh.service
	run systemctl reload ssh.service
```

`sshd -t` **tests** the config for errors. If it fails, `die` *without* reloading —
because reloading a broken SSH config on a remote box is how you lose access
forever. Only if the test passes do we ensure SSH is enabled and `reload` it
(reload applies the new config without dropping existing connections).

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

BBR is a faster network algorithm, but it's a kernel *module* that isn't on every
board. `modprobe tcp_bbr` tries to load it (`2>/dev/null || true` = "ignore any
error, don't let it stop the script"). Then we check: does the kernel now list
`bbr` as available? `grep -qw bbr /proc/.../tcp_available_congestion_control`
looks for the whole word `bbr` in that special kernel file. If yes (or if we're
just rehearsing), we prepare two config lines in `cc_lines` — enabling BBR and its
companion queueing method `fq` — *and* write a `modules-load.d` file so the module
loads automatically on every boot. If BBR *isn't* available, we skip it and warn,
because writing a sysctl for a feature the kernel lacks would make the whole
config fail to apply. `cc_lines` gets injected into the big config below;
`$'...\n...'` is bash's way of putting a real newline in a string.

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

Write all the kernel dials into one file (unquoted heredoc so `$cc_lines` expands),
then `sysctl --system` applies every setting immediately. The values and *why*
each one (especially `swappiness = 100` and `rp_filter = 2`) are covered in
`harden.md`.

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

Install the firewall tool, then write the ruleset. Reading the rules:

- `flush ruleset` — wipe any existing rules first, so we start clean.
- `table inet filter` — a container for rules covering both IPv4 and IPv6
  (`inet`).
- `chain input { ... policy drop; }` — rules for *incoming* traffic; `policy drop`
  is the crucial default: **anything not explicitly allowed is rejected.**
- `ct state established,related accept` — allow replies to connections *you*
  started (`ct` = connection tracking).
- `ct state invalid drop` — throw away malformed/nonsense packets.
- `iif lo accept` — allow the machine to talk to itself (`lo` = loopback).
- `iifname "tailscale0" accept` — allow *everything* arriving over the Tailscale
  interface (that traffic is already encrypted and authenticated).
- `meta l4proto icmp accept` (and `ipv6-icmp`) — allow ping and, more importantly,
  the path-MTU messages real connections depend on.
- `udp dport 68 accept` — allow DHCP replies so the box can get an IP address.
- `tcp dport 22 accept` — allow SSH.
- `chain forward { ... policy drop; }` — traffic being *routed through* the box:
  denied (this box isn't a router; rootless Podman doesn't need it).
- `chain output { ... policy accept; }` — *outgoing* traffic: allowed freely.

```bash
	if [ "$DRY_RUN" != 1 ]; then
		nft -c -f /etc/nftables.conf || die "nftables ruleset failed validation — not enabling"
	fi
	enable_now nftables.service
```

`nft -c -f` **checks** the ruleset parses correctly *without* loading it. If it's
broken, `die` — because a firewall that fails to load leaves you with *no*
firewall, and one that loads wrong could lock out SSH. Only a valid ruleset gets
enabled. `main` (lines 200–206) just calls the three layers in order.

---

## `setup/tailscale.sh`

The secret tunnel. The interesting work is picking the right package repo.

### `detect_repo` (lines 31–54)

```bash
	# shellcheck disable=SC1091
	. /etc/os-release
```

`/etc/os-release` is a file of variables describing the distro (`ID=debian`,
`VERSION_CODENAME=bookworm`, etc.). Sourcing it with `.` loads those variables
into the script. (`# shellcheck disable=SC1091` tells the linter "yes I know I'm
sourcing a file you can't follow, that's fine.")

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

Tailscale only publishes packages for `debian` and `ubuntu`, but lots of distros
are those two in disguise. So: if you haven't forced `TS_DISTRO` yourself
(`[ -z ... ]` = "is it empty?"), figure it out. First check `ID` directly —
`debian` and `raspbian` map to debian; `ubuntu`, `linuxmint`, `pop` map to ubuntu.
If `ID` is something else (`*`), fall back to `ID_LIKE`, which lists the parent
distros — the `*" ubuntu "*` pattern (note the spaces) checks if "ubuntu" appears
as a word in that list. Still no match? `die` and ask you to set it manually. This
is how it handles Armbian and friends.

```bash
	TS_CODENAME="${TS_CODENAME:-${VERSION_CODENAME:-}}"
	[ -n "$TS_CODENAME" ] || die "no VERSION_CODENAME in /etc/os-release — set TS_CODENAME"
```

The codename (like `bookworm`) picks *which version's* repo. Use your override if
set, else the one from os-release, else `die`.

### `add_repo` (lines 56–80)

```bash
	local base="https://pkgs.tailscale.com/stable/$TS_DISTRO/$TS_CODENAME"
	if [ "$DRY_RUN" != 1 ] && ! curl -fsI "$base.noarmor.gpg" >/dev/null 2>&1; then
		die "Tailscale publishes no repo for $TS_DISTRO/$TS_CODENAME — ..."
	fi
```

Build the repo URL from the distro + codename we detected. Then `curl -fsI` does a
*headers-only* test fetch of the signing key (`-I` = "just check it's there, don't
download it," `-f` = "fail on a 404," `-s` = "quietly"). If that fails, the repo
doesn't exist for your system — `die` now, rather than writing a broken repo that
makes every future `apt update` spew 404 errors.

```bash
	if [ -s "$KEYRING" ]; then
		ok "unchanged: $KEYRING"
	else
		run curl -fsSL "$base.noarmor.gpg" -o "$KEYRING"
		run chmod 0644 "$KEYRING"
	fi
```

Download the signing key (the thing that proves packages really came from
Tailscale) — but only if it isn't already there (`[ -s ... ]` = "exists and
non-empty"), keeping the run idempotent. `-o` saves it to the keyring path;
`chmod 0644` makes it world-readable (apt needs to read it).

```bash
	if [ -s "$LIST" ]; then
		ok "unchanged: $LIST"
	else
		run curl -fsSL "$base.tailscale-keyring.list" -o "$LIST"
		run chmod 0644 "$LIST"
		_APT_UPDATED=
	fi
```

Same pattern for the sources list (the file that tells apt "there's a Tailscale
repo over here"). `_APT_UPDATED=` clears the "already updated apt" flag — because
we just added a new repo, the next `apt_install` *must* run `apt-get update`
again to see it.

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

If already logged in (`tailscale status` succeeds), report the machine's Tailscale
IP and stop. Otherwise, if you supplied an auth key, use it to join
non-interactively (`--ssh` also turns on Tailscale's SSH feature). No key? We
*can't* log in for you (it needs a browser), so warn and tell you the command.
`main` (lines 96–105) wires it together: install prerequisites, detect the repo,
add it, install tailscale, enable the service, try to join.

---

## `setup/podman.sh`

The container house. Several small guard functions, each fixing one rootless
gotcha.

### `user_home` (line 29)

```bash
user_home() { getent passwd "$1" | cut -d: -f6; }
```

Look up a user's home directory (same `getent | cut -f6` trick as before). `$1` is
"the first argument passed to this function."

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

Rootless containers need a block of "sub-user-IDs" delegated to your user. Check
whether `/etc/subuid` and `/etc/subgid` already have a line starting with your
username (`grep -q "^$u:"`); if both do, nothing to do. Otherwise install `uidmap`
(the tool that makes the mapping work), then `usermod --add-subuids ...` hands your
user IDs 100000–165535 to use inside containers. Finally
`runuser -u "$u" -- podman system migrate` runs a podman command *as that user*
(`runuser` = "run as another user," `--` separates its options from the command) to
make podman forget its old cached "you have no IDs" answer. Skip this last step and
containers keep failing even after you've fixed the mapping.

### `ensure_linger` (lines 48–56)

```bash
	if [ "$DRY_RUN" != 1 ] && loginctl show-user "$u" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
		ok "lingering already enabled for $u"
		return 0
	fi
	log "enabling lingering for $u"
	run loginctl enable-linger "$u"
```

"Lingering" lets a user's services keep running when they're not logged in —
essential on a headless box, or containers would die at every reboot. Check the
current state (`loginctl show-user ... -p Linger` prints `Linger=yes` or `no`); if
already on, done. Otherwise `enable-linger`.

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

Quadlet reads container definitions from this specific folder in the user's home.
If it already exists, done; otherwise create it *as the user* (so they own it, not
root). `mkdir -p` creates any missing parent folders too.

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

Quadlet needs podman ≥ 4.4. `podman --version` prints something like "podman
version 4.9.3"; `awk '{print $3}'` grabs the third word, the number. If we can't
get it, warn and move on. `dpkg --compare-versions "$ver" ge "4.4"` is a proper
version comparison (`ge` = "greater than or equal"); it either reassures you or
warns that you're on an older release where you'll use `podman generate systemd`
instead. It only *warns* — it never blocks the setup.

### `main` (lines 80–110)

```bash
	u="$(target_user)"
	[ -n "$u" ] || die "no unprivileged user found — run via sudo, or set TARGET_USER"
	id "$u" >/dev/null 2>&1 || die "user '$u' does not exist"
```

Figure out the owner and sanity-check it: non-empty, and a real account (`id "$u"`
succeeds only for a real user). Then install podman, check Quadlet support, and run
the three `ensure_` guards. The closing `cat >&2 <<EOF ... EOF` just prints a
worked example of a Quadlet file so you know what to do next. (`cat >&2` prints the
block to the messages channel.)

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

Same owner-detection as podman, plus two more lookups: the home directory (where
the dotfiles go) and `id -gn "$u"`, the user's primary *group name* (needed so the
files are owned by `user:group`). The `if [ -z ] || [ ! -d ]` guards against a
missing or bogus home. (This is the `SC2015` fix from earlier — written as a proper
`if` rather than `A && B || die`, which could fire `die` even when the home was
fine.)

```bash
	apt_install zsh zsh-syntax-highlighting zsh-autosuggestions tmux
```

Install the shell, its two plugin packages (from apt — no downloads), and tmux.

```bash
	install_file "$home/.zshrc" 0644 "$u:$grp" <<'EOF'
... zsh config ...
EOF
```

Write `.zshrc` — note the third argument `"$u:$grp"`, which makes the file
*user-owned*, not root-owned. That matters: zsh ignores a config file owned by
someone else. The `'EOF'` is quoted so the `$` symbols in the prompt string stay
literal instead of being expanded now. What each config line does (history,
`compinit -C`, the `vcs_info` git prompt, the plugin sourcing order) is explained
in `shell.md`.

```bash
	install_file "$home/.tmux.conf" 0644 "$u:$grp" <<'EOF'
... tmux config ...
EOF
```

Same for `.tmux.conf`, also user-owned. Config choices (prefix `C-a`,
`screen-256color`, `escape-time 10`, the splits and pane movement) are in
`shell.md`.

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

Change the login shell to zsh — carefully, via a four-way `if`/`elif` ladder:

1. `command -v zsh` finds zsh's full path (`|| true` so a not-found doesn't trip
   `set -e`).
2. If you set `SHELL_NO_CHSH=1`, respect that and don't touch the shell.
3. If zsh somehow isn't on the PATH, warn and skip.
4. If your shell (field 7 of the passwd record) is *already* zsh, nothing to do —
   this is what makes re-running idempotent.
5. Otherwise, `chsh -s "$zsh_bin" "$u"` sets it. It takes effect next login, which
   the final `ok` message reminds you.

---

## `setup/monitor.sh`

The shortest stage. Its whole `main`:

```bash
	apt_install prometheus-node-exporter
	enable_now prometheus-node-exporter.service
	if [ "$DRY_RUN" != 1 ] && ! nft list table inet filter >/dev/null 2>&1; then
		warn "no nftables ruleset loaded — :9100 is exposed on every interface"
		warn "run setup/harden.sh, or firewall port 9100 yourself"
	fi
	ok "node_exporter listening on :9100"
```

Install the metrics exporter and turn it on. Then the safety check:
`nft list table inet filter` asks the firewall "do you have the ruleset from
harden.sh loaded?" If that *fails* (`!` = "not") — meaning no firewall — warn
loudly, because the exporter listens on every network interface and only the
firewall keeps port 9100 private. The exporter isn't secured by itself; it's
secured by the wall around it. See `monitor.md`.

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

A cousin of `install_file`, with one crucial difference: it **never overwrites**.
These files hold secrets (your backup password) and your own edits (the repo
location), so once they exist we leave them completely alone. If the destination
exists, say so and stop — but note `cat >/dev/null`: the caller is still piping
content in via a heredoc, and if we didn't *consume* that input the script would
misbehave, so we read it and throw it away (`/dev/null` = the void). Dry-run
likewise previews and discards. Only when the file is genuinely absent do we
create it.

### `write_config` (lines 54–102)

```bash
	run install -d -m 0700 "$ETC"
```

Create `/etc/restic` as a directory (`-d`) with mode `0700` (only root can even
look inside — it holds the encryption key).

```bash
	create_if_absent "$ENV_FILE" 0600 <<'EOF'
...
RESTIC_REPOSITORY=
RESTIC_PASSWORD_FILE=/etc/restic/password
RESTIC_CACHE_DIR=/var/cache/restic
EOF
```

Create the env file (mode `0600` = only root can read/write) with `RESTIC_REPOSITORY`
deliberately *blank* — you fill it in. The comments show example destinations (a
NAS over SFTP, an S3 bucket, a USB path).

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

Generate the encryption key, once. `head -c 32 /dev/urandom` reads 32 random bytes
from the kernel's randomness source; `base64` turns them into safe text
characters; that gets piped into `create_if_absent` as the file content. Then a big
warning prints — because if you lose this key, your backups are permanently
unreadable. The `else` branch (used during dry-run, or if the key already exists)
calls `create_if_absent` with `</dev/null` — empty input — because we don't want a
real key generated during a rehearsal.

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

Two plain lists: what to back up (`/etc` config, `/home` your files) and what to
skip (caches, `node_modules`, git internals, container storage — bulky stuff you
can regenerate). `**` means "any depth of folders."

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

The backup *job* itself, as a systemd service. Line by line:

- `Wants=/After=network-online.target` — don't start until the network is up (you
  can't reach a remote backup repo without it).
- `Type=oneshot` — this runs, finishes, and exits (not a service that stays
  running).
- `EnvironmentFile=/etc/restic/env` — load your repo location and credentials.
- `CacheDirectory=restic` — systemd provides `/var/cache/restic` automatically.
- `Nice=19` and `IOSchedulingClass=idle` — run at the *lowest* CPU and disk
  priority, so a backup never bogs down a one-core SBC.
- `PrivateTmp`, `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only` —
  sandboxing. The job gets a private temp folder, can't gain new privileges, sees
  most of the filesystem as read-only, and can only *read* home directories (it's
  backing them up, not changing them). `full` rather than `strict` so a repo on
  `/mnt` or `/srv` still works — see `backup.md`.
- `ExecStartPre=-/usr/bin/restic init` — before backing up, create the repository.
  The leading `-` means "if this fails, carry on anyway" — because after the first
  time, "init" correctly fails ("already exists") and we don't want that to abort
  the backup.
- `ExecStart=... restic backup ...` — the actual backup, reading the paths and
  excludes files.
- `ExecStartPost=... restic forget --prune ...` — afterward, delete old snapshots
  beyond the retention window (7 daily, 4 weekly, 6 monthly) and reclaim the space.

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

The *schedule*. `OnCalendar=daily` = run once a day. `RandomizedDelaySec=1h` =
jitter the start by up to an hour (so many machines don't all hammer the backup
server at midnight). `Persistent=true` = if the box was off at the scheduled time,
run the backup at next boot. `WantedBy=timers.target` = start this timer on boot.
`systemctl daemon-reload` makes systemd re-read these two new unit files.

### `repo_configured` (lines 150–153)

```bash
repo_configured() {
	[ -r "$ENV_FILE" ] || return 1
	grep -qE '^[[:space:]]*RESTIC_REPOSITORY=[^[:space:]]' "$ENV_FILE"
}
```

Have you set a backup destination yet? Only if the env file is readable *and* it
has a `RESTIC_REPOSITORY=` line with something non-blank after the `=`
(`[^[:space:]]` = "a non-whitespace character"). Notice it *greps* the file rather
than *sourcing* (running) it — because a config file you edit by hand shouldn't be
executed; a stray backtick could run a command. Searching is safe.

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

Install restic, write the config and the units, then decide about the timer. In a
rehearsal, leave it alone. If you've configured a destination, enable the daily
timer. If not, *deliberately* leave it disabled and tell you why — a backup job
pointing at nothing looks healthy while protecting nothing, which is worse than no
job at all. Re-run once you've set the destination and it flips on.

---

## `setup/bootstrap.sh`

The conductor that runs all seven stages.

```bash
STAGES=(base harden tailscale podman shell monitor backup)
```

The ordered list. Order is load-bearing (see the header comment and each stage's
doc): `harden` must set the firewall rule welcoming Tailscale *before* `tailscale`
arrives, and `monitor` is only safe because `harden` already ran.

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

Lets you leave stages out with `SKIP="tailscale monitor"`. It walks the words in
`SKIP` and returns success (0 = "yes, skip it") if the stage name matches. `${SKIP:-}`
is "the value of SKIP, or empty if unset" — the `:-` keeps `set -u` from
complaining about an undefined variable.

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

Build an argument list: if we're in dry-run, add `--dry-run` so it gets passed
down to every stage. Then loop the stages in order: skip the ones you asked to
skip (`continue` jumps to the next loop iteration), print a header, and run the
stage script. `"$SELF_DIR/$stage.sh"` is the full path to, e.g.,
`setup/harden.sh`. The `${args[@]+"${args[@]}"}` incantation means "expand the
args list if it has anything in it, otherwise expand to nothing" — a safe way to
pass an array that might be empty without tripping `set -u`.

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

Announce completion. In a rehearsal, stop here. In a real run, print the manual
follow-ups the scripts *deliberately* don't do for you: log in to Tailscale, copy
your restic key somewhere safe, set the backup destination, and finish the SSH
lockdown once your key is in place. These are the steps that need a human decision
or a browser — the automation takes you right up to them and no further.

---

That's every line that does something. The recurring themes, one more time:
**validate before you apply** (sshd, nftables), **check before you change**
(idempotence), **back up before you overwrite** (reversibility), and **fail loudly
rather than pretend** (the guards that `die`). Those four ideas are the whole
personality of the project.
