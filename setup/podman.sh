#!/usr/bin/env bash
# podman.sh — rootless container host, with Quadlet units managed by systemd.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: podman.sh [--dry-run] [--help]

Sets up a daemonless, rootless container host:
  * installs podman
  * allocates subuid/subgid ranges so rootless user namespaces work
  * enables lingering so the user's containers start at boot without a login
  * creates ~/.config/containers/systemd for Quadlet unit files

The unprivileged owner is taken from $SUDO_USER, or $TARGET_USER when running
as root directly.

Quadlet needs podman >= 4.4. On older releases the script still installs
podman and warns; drive containers with `podman generate systemd` instead.

Idempotent. Safe to re-run.
EOF
}

QUADLET_MIN=4.4

user_home() { getent passwd "$1" | cut -d: -f6; }

# Rootless podman maps container UIDs into a delegated range owned by the user.
# Without an /etc/subuid entry every `podman run` fails with a newuidmap error.
ensure_subids() {
	local u="$1"
	if grep -q "^$u:" /etc/subuid 2>/dev/null && grep -q "^$u:" /etc/subgid 2>/dev/null; then
		ok "subuid/subgid present for $u"
		return 0
	fi
	log "allocating subuid/subgid range for $u"
	apt_install uidmap
	run usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$u"
	# podman caches the old (empty) mapping; force it to re-read.
	run runuser -u "$u" -- podman system migrate
}

# Without linger, the user's systemd instance is torn down at logout, taking
# every rootless container with it — so nothing survives a reboot.
ensure_linger() {
	local u="$1"
	if [ "$DRY_RUN" != 1 ] && loginctl show-user "$u" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
		ok "lingering already enabled for $u"
		return 0
	fi
	log "enabling lingering for $u"
	run loginctl enable-linger "$u"
}

ensure_quadlet_dir() {
	local u="$1" dir
	dir="$(user_home "$u")/.config/containers/systemd"
	if [ -d "$dir" ]; then
		ok "unchanged: $dir"
		return 0
	fi
	log "creating Quadlet unit directory $dir"
	run runuser -u "$u" -- mkdir -p "$dir"
}

check_quadlet_support() {
	local ver
	ver="$(podman --version 2>/dev/null | awk '{print $3}')" || ver=''
	[ -n "$ver" ] || { warn "cannot determine podman version"; return 0; }
	if dpkg --compare-versions "$ver" ge "$QUADLET_MIN"; then
		ok "podman $ver supports Quadlet"
	else
		warn "podman $ver is older than $QUADLET_MIN — Quadlet unavailable on this release"
	fi
}

main() {
	require_apt_systemd

	local u
	u="$(target_user)"
	[ -n "$u" ] || die "no unprivileged user found — run via sudo, or set TARGET_USER"
	id "$u" >/dev/null 2>&1 || die "user '$u' does not exist"
	log "configuring rootless podman for user '$u'"

	apt_install podman
	[ "$DRY_RUN" = 1 ] || check_quadlet_support

	ensure_subids "$u"
	ensure_linger "$u"
	ensure_quadlet_dir "$u"

	cat >&2 <<EOF

Drop a Quadlet unit at ~/.config/containers/systemd/<name>.container, e.g.

    [Container]
    Image=docker.io/library/caddy:alpine
    PublishPort=8080:80

    [Install]
    WantedBy=default.target

then: systemctl --user daemon-reload && systemctl --user start <name>
EOF
	ok "rootless podman ready for $u"
}

parse_common_args "$@"
require_root "$@"
main
