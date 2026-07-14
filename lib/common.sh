# shellcheck shell=bash
# common.sh — shared helpers for steves-sbc-setup.
# Sourced by every setup/*.sh script; never executed directly.

set -euo pipefail

# --- paths (resolved from the entry script, not this library) ---------------
SELF="$(readlink -f "${BASH_SOURCE[-1]}")"
SELF_DIR="$(dirname "$SELF")"
REPO_DIR="$(dirname "$SELF_DIR")"
export SELF SELF_DIR REPO_DIR

# --- logging ----------------------------------------------------------------
if [ -t 2 ]; then
	C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[34m' C_0=$'\e[0m'
else
	C_R='' C_G='' C_Y='' C_B='' C_0=''
fi
log()  { printf '%s==>%s %s\n'  "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

DRY_RUN="${DRY_RUN:-0}"

# run CMD... — print instead of executing under DRY_RUN=1.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '%s[dry]%s %s\n' "$C_Y" "$C_0" "$*" >&2
	else
		"$@"
	fi
}

# --- argument handling ------------------------------------------------------
# Each script defines usage(); this parses the two universal flags.
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

# Every environment knob any script reads. sudo scrubs the environment, and
# `sudo -E` is commonly forbidden by sudoers, so each one has to be forwarded by
# name on the sudo command line — otherwise `SHELL_RICH=1 ./setup/shell.sh`
# silently takes the default path.
SUDO_KEEP=(
	DRY_RUN SKIP TARGET_USER
	FORCE_SSH_KEYONLY
	TS_AUTHKEY TS_DISTRO TS_CODENAME
	SHELL_RICH SHELL_NO_CHSH
	APPS DFS_REPO DFS_REF
	XFCE_YES XFCE_PURGE_X
)

# Re-exec under sudo if not already root, preserving SUDO_KEEP vars and args.
# NOTE: guard clauses are written `if ...; then return; fi` rather than
# `[ ... ] && return`, because under `set -e` a trailing false && list makes
# the whole script exit.
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

# --- platform guards --------------------------------------------------------
require_apt_systemd() {
	command -v apt-get >/dev/null 2>&1 || die "unsupported: needs an apt distro (Debian/Ubuntu/Armbian)"
	[ -d /run/systemd/system ] || die "unsupported: systemd is required"
}

# The Debian package architecture, e.g. arm64 / amd64.
arch() { dpkg --print-architecture; }

# The unprivileged user this box belongs to (scripts run as root via sudo).
target_user() { printf '%s' "${SUDO_USER:-${TARGET_USER:-}}"; }

# --- apt helpers ------------------------------------------------------------
apt_update_once() {
	if [ -n "${_APT_UPDATED:-}" ]; then
		return 0
	fi
	run apt-get update
	_APT_UPDATED=1
}

# Install only the packages that are missing (keeps re-runs quiet and fast).
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

# --- idempotent file install ------------------------------------------------
# install_file DEST [MODE] [OWNER]   (content on stdin)
# Writes only when content differs; backs up any file it replaces. OWNER, when
# given as user:group, sets ownership (used for dotfiles in a user's home).
install_file() {
	local dest="$1" mode="${2:-0644}" owner="${3:-}" tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		ok "unchanged: $dest"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would write $dest (mode $mode${owner:+, owner $owner}):"
		sed 's/^/      /' "$tmp" >&2
		rm -f "$tmp"
		return 0
	fi
	if [ -f "$dest" ]; then
		cp -a "$dest" "$dest.bak.$(date +%s)"
		warn "backed up existing $dest"
	fi
	if [ -n "$owner" ]; then
		install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
	else
		install -D -m "$mode" "$tmp" "$dest"
	fi
	rm -f "$tmp"
	ok "wrote $dest"
}

# enable_now UNIT — enable + start a system unit (idempotent).
enable_now() { run systemctl enable --now "$1"; }
