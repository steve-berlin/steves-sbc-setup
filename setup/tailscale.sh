#!/usr/bin/env bash
# tailscale.sh — mesh VPN for reaching this box from anywhere.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: tailscale.sh [--dry-run] [--help]

Adds the official Tailscale apt repository, installs tailscale, and enables
tailscaled. The box is NOT joined to a tailnet automatically, because that
needs an interactive browser login.

  * set TS_AUTHKEY=tskey-auth-...  to join non-interactively
  * otherwise run `sudo tailscale up` afterwards and follow the URL

Repository selection is derived from /etc/os-release. Override the detected
values with TS_DISTRO (debian|ubuntu) and TS_CODENAME (e.g. bookworm) when
running a derivative Tailscale does not publish for.

Idempotent. Safe to re-run.
EOF
}

KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list

# Tailscale publishes only for debian and ubuntu. Derivatives (Armbian,
# Raspberry Pi OS, Mint) must be mapped onto whichever base they track.
detect_repo() {
	# shellcheck disable=SC1091
	. /etc/os-release

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

	TS_CODENAME="${TS_CODENAME:-${VERSION_CODENAME:-}}"
	[ -n "$TS_CODENAME" ] || die "no VERSION_CODENAME in /etc/os-release — set TS_CODENAME"

	log "tailscale repo: $TS_DISTRO/$TS_CODENAME"
}

add_repo() {
	local base="https://pkgs.tailscale.com/stable/$TS_DISTRO/$TS_CODENAME"

	# Fail loudly on an unpublished codename rather than writing a repo that
	# silently 404s on every apt update from now on.
	if [ "$DRY_RUN" != 1 ] && ! curl -fsI "$base.noarmor.gpg" >/dev/null 2>&1; then
		die "Tailscale publishes no repo for $TS_DISTRO/$TS_CODENAME — override TS_DISTRO/TS_CODENAME"
	fi

	if [ -s "$KEYRING" ]; then
		ok "unchanged: $KEYRING"
	else
		run curl -fsSL "$base.noarmor.gpg" -o "$KEYRING"
		run chmod 0644 "$KEYRING"
	fi

	# Tailscale's own .list already carries the signed-by= pin.
	if [ -s "$LIST" ]; then
		ok "unchanged: $LIST"
	else
		run curl -fsSL "$base.tailscale-keyring.list" -o "$LIST"
		run chmod 0644 "$LIST"
		_APT_UPDATED=
	fi
}

join_tailnet() {
	if [ "$DRY_RUN" != 1 ] && tailscale status >/dev/null 2>&1; then
		ok "already joined to a tailnet as $(tailscale ip -4 2>/dev/null || echo '?')"
		return
	fi
	if [ -n "${TS_AUTHKEY:-}" ]; then
		log "joining tailnet with supplied auth key"
		run tailscale up --authkey "$TS_AUTHKEY" --ssh
		[ "$DRY_RUN" = 1 ] || ok "joined as $(tailscale ip -4 2>/dev/null || echo '?')"
		return
	fi
	warn "not joined to a tailnet yet — run: sudo tailscale up"
}

main() {
	require_apt_systemd
	apt_install ca-certificates curl gnupg
	detect_repo
	add_repo
	apt_install tailscale
	enable_now tailscaled.service
	join_tailnet
	ok "tailscale ready"
}

parse_common_args "$@"
require_root "$@"
main
