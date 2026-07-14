# `lib/common.sh` explained

Plain-language walkthrough of shared toolbox. Every other script start by loading this. It never run on its own.

## What it's for

Ten scripts need same handful of things: print message, ask for root, install package, write file safely, rehearse instead of act. Write that ten times = ten chances to write it slightly differently, and ten places to fix when one is wrong.

So: one file, ~130 lines, sourced by everyone.

```bash
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
```

`readlink -f "$0"` = "real full path of script running, even if it was reached through symlink." Take its folder, go up one, go into `lib/`. Means scripts work no matter where you call them from — `./setup/base.sh`, `~/steves-sbc-setup/setup/base.sh`, doesn't matter.

## Knowing where it is

```bash
SELF="$(readlink -f "${BASH_SOURCE[-1]}")"
SELF_DIR="$(dirname "$SELF")"
REPO_DIR="$(dirname "$SELF_DIR")"
```

`BASH_SOURCE` = list of files in current call chain. `[-1]` = *last* one = script you actually ran, **not** this library. That distinction matter: `require_root` re-launch `$SELF` under sudo, and re-launching the library would do nothing at all.

## Talking to you

```bash
log()  { printf '%s==>%s %s\n'  "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
```

Four voices: doing thing / worked / careful / stop. All go to **stderr**, not stdout — so you could pipe script's output somewhere useful and not have progress chatter contaminate it.

Colours only when someone watching:

```bash
if [ -t 2 ]; then
	C_R=$'\e[31m' … 
else
	C_R='' …
fi
```

`-t 2` = "is stderr a terminal?" Yes = colour codes. No (piped to file, run from cron) = empty strings, so log file don't fill with `\e[31m` garbage.

## Rehearsal mode

```bash
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '%s[dry]%s %s\n' "$C_Y" "$C_0" "$*" >&2
	else
		"$@"
	fi
}
```

Whole `--dry-run` feature = this one function. Every dangerous command in repo written `run apt-get install …`, not `apt-get install …`. Rehearsing? Print it. Real? Do it.

Rule: if command *change* something, it go through `run`. If it only *look* at something (`id -u`, `command -v`, `grep`), call it directly — reading is safe, and dry run that can't read can't decide anything.

## Becoming root

```bash
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
	exec sudo "${pass[@]}" "$SELF" "$@"
}
```

Already root = nothing to do. Otherwise **replace self** with same script running under sudo (`exec` = "become that process"; nothing after this line run in old one). You never type `sudo` yourself — script do it when it need it.

**`SUDO_KEEP` earn its own paragraph.** sudo throw your environment variables away on purpose (security), and `sudo -E` (keep everything) usually forbidden by sudoers config. So every knob repo understands — `SHELL_RICH`, `TS_AUTHKEY`, `SKIP`, `APPS`, `XFCE_YES`, … — must be handed over *by name*. Loop build those `NAME=value` pairs. `${!v+x}` = indirect look-up: `v` hold *name* of variable, `${!v}` fetch that name's value.

Got this wrong once: `SHELL_RICH=1 ./setup/shell.sh` jumped through sudo, lost variable, quietly installed lean shell, and starship never appeared. Add new env knob to any script → add it to `SUDO_KEEP` too.

**Why long `if` instead of `[ cond ] && return 0`?** Signature bug of this project. Scripts run under `set -e` = "die on any failed command." Write `[ "$(id -u)" -eq 0 ] && return 0` and you *not* root, test is false, whole `&&` line counts as failed command, `set -e` kill script on spot. Result: script silently exit instead of escalating. Every guard in repo written long way for this reason.

## Installing packages

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

Ask dpkg what already installed, install only rest. Re-run script on configured box = instant, no apt at all.

`apt_update_once` remember it ran (`_APT_UPDATED=1`) so five stages don't re-download package lists five times — slow on SBC, pointless.

`--no-install-recommends` = "only what package actually need, not what it *suggests*." On desktop that annoying; on 2 GB board with SD card it difference between lean install and dragging half a desktop in.

`DEBIAN_FRONTEND=noninteractive` = never stop to ask questions. Script running unattended can't answer them anyway.

## Writing files safely

```bash
install_file() {
	local dest="$1" mode="${2:-0644}" owner="${3:-}" tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"; ok "unchanged: $dest"; return 0
	fi
	…
	if [ -f "$dest" ]; then
		cp -a "$dest" "$dest.bak.$(date +%s)"
	fi
	install -D -m "$mode" … "$tmp" "$dest"
}
```

Whole "idempotent + reversible" promise of repo live here:

1. New content go to temp file first.
2. `cmp -s` compare it to what already there. Same? Delete temp, say "unchanged", done — **no write at all**. That why re-running scripts is cheap and quiet.
3. Different? Copy old file to `<file>.bak.<seconds-since-1970>` first. Nothing this repo replace is ever simply gone.
4. Then `install -D` put new one in place with right permissions (`-D` also create parent folders).

Optional third argument `OWNER` (`steve:steve`) used for dotfiles: `~/.zshrc` owned by root is file zsh **ignore**, so `shell.sh` pass owner and file end up belonging to human.

Content come in on stdin, so callers write:

```bash
install_file /etc/sysctl.d/99-sbc.conf <<'EOF'
vm.swappiness = 100
EOF
```

Dry run print what it *would* write, indented, instead of writing.

## Small stuff

```bash
arch() { dpkg --print-architecture; }          # arm64 / amd64
target_user() { printf '%s' "${SUDO_USER:-${TARGET_USER:-}}"; }
enable_now() { run systemctl enable --now "$1"; }
```

`target_user` answer question "who does this box belong to?" Scripts run as root, but zsh config, podman containers and music folder belong to *human*. `$SUDO_USER` = account that typed `sudo`. Running as root directly (no sudo) = set `TARGET_USER` yourself.

`enable_now` = start service now **and** at every boot. Two things, one word, so nobody forget second one.

## How it was checked

- `shellcheck -x` clean (with `.shellcheckrc` telling it to follow the `source` line).
- Never executed directly — `# shellcheck shell=bash` header at top say "this is a library, judge it as bash."
- Every helper here exercised by the `--dry-run` smoke test on `bootstrap.sh`.
