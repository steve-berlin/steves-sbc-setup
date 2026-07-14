#!/usr/bin/env bash
# remove-xfce.sh — strip an XFCE desktop off a box meant to be headless.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: remove-xfce.sh [--dry-run] [--help]

Purges the XFCE desktop, its apps and its display manager, then sets the boot
target to multi-user (console, no graphical login). On a 2 GB headless board
that is a few hundred MB of RAM and a lot of disk back.

DESTRUCTIVE and not undone by re-running: purge removes package config too.
Preview first:

    ./setup/remove-xfce.sh --dry-run

Then confirm interactively, or set XFCE_YES=1 to skip the prompt.

XFCE_PURGE_X=1 additionally purges the X server itself (xserver-xorg*, xinit).
Leave it unset if anything still needs X — a VNC/RDP server, or an X11 app you
run headless via Xvfb.

It refuses to run from inside a graphical session (that would kill the session
mid-purge) unless XFCE_YES=1.

Not part of bootstrap.sh — nothing here is reversible, so it is never automatic.
EOF
}

# Top-level desktop packages. Libraries (libxfce4*, X modules, GTK themes) are
# left to `autoremove --purge`, which pulls them once nothing depends on them.
PATTERNS=(
	'xfce4*' 'xfdesktop4*' 'xfwm4*' 'xfconf*' 'xfce4-*'
	'thunar*' 'exo-utils' 'garcon' 'tumbler*'
	'mousepad' 'ristretto' 'parole' 'xfburn' 'orage' 'catfish'
	'lightdm*' 'xscreensaver*'
)
X_PATTERNS=('xserver-xorg*' 'xinit' 'x11-xserver-utils')

# Installed packages matching the patterns, one per line.
matching_packages() {
	local pkg status pat
	while read -r pkg status; do
		[ "$status" = installed ] || continue
		for pat in "$@"; do
			# shellcheck disable=SC2254  # $pat is a glob on purpose
			case "$pkg" in
				$pat) printf '%s\n' "$pkg"; break ;;
			esac
		done
	done < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null)
}

confirm() {
	if [ "${XFCE_YES:-0}" = 1 ]; then
		return 0
	fi
	if [ ! -t 0 ]; then
		die "not a terminal and XFCE_YES is unset — refusing to purge unattended"
	fi
	printf 'Purge the %s packages above? [y/N] ' "$1" >&2
	local reply
	read -r reply
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) die "aborted" ;;
	esac
}

main() {
	require_apt_systemd

	# Running this from an XFCE terminal purges the desktop out from under the
	# terminal you are typing in. Refuse unless the operator insists. A dry run
	# changes nothing, so previewing from the desktop is allowed.
	if [ "$DRY_RUN" != 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "${XFCE_YES:-0}" != 1 ]; then
		die "a graphical session is active — run this from a TTY or over SSH (or set XFCE_YES=1)"
	fi

	local pats=("${PATTERNS[@]}")
	if [ "${XFCE_PURGE_X:-0}" = 1 ]; then
		pats+=("${X_PATTERNS[@]}")
	fi

	local pkgs=()
	mapfile -t pkgs < <(matching_packages "${pats[@]}")
	if [ "${#pkgs[@]}" -eq 0 ]; then
		ok "no XFCE packages installed — nothing to do"
		return 0
	fi

	log "${#pkgs[@]} packages to purge:"
	printf '      %s\n' "${pkgs[@]}" >&2

	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would purge the above, then autoremove --purge"
	else
		confirm "${#pkgs[@]}"
		run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
	fi
	run env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

	# With no display manager left, graphical.target has nothing to start and
	# boot would stall waiting on it.
	if [ "$(systemctl get-default 2>/dev/null)" = graphical.target ]; then
		log "switching default boot target to multi-user.target (console)"
		run systemctl set-default multi-user.target
	else
		ok "boot target already multi-user.target"
	fi

	ok "XFCE removed — reboot to boot straight to a console"
	warn "per-user leftovers (~/.config/xfce4, ~/.cache/sessions) are left alone; delete them yourself if you want"
}

parse_common_args "$@"
require_root "$@"
main
