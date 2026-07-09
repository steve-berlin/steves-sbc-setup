#!/usr/bin/env bash
# bootstrap.sh — run every setup stage, in dependency order.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: bootstrap.sh [--dry-run] [--help]

Runs each stage in order:

    base       packages, chrony, zram, unattended-upgrades
    harden     sshd lockdown, sysctl tuning, nftables default-deny
    tailscale  mesh VPN (joins only if TS_AUTHKEY is set)
    podman     rootless container host + Quadlet
    monitor    prometheus-node-exporter on :9100
    backup     restic + daily systemd timer

Order matters: harden installs the firewall rule that admits tailscale0
before tailscale.sh brings the interface up, and monitor.sh relies on that
same ruleset to keep :9100 off the public internet.

Skip stages with SKIP, e.g.  SKIP="tailscale monitor" ./bootstrap.sh

Every stage is individually idempotent; so is this.
EOF
}

STAGES=(base harden tailscale podman monitor backup)

skipped() {
	local s
	for s in ${SKIP:-}; do
		if [ "$s" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

main() {
	require_apt_systemd

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

	ok "bootstrap complete"
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi

	cat >&2 <<'EOF'

Next steps:
  1. sudo tailscale up                  (if TS_AUTHKEY was not supplied)
  2. sudo cat /etc/restic/password      (store this off-box, or backups are lost)
  3. edit /etc/restic/env, then re-run setup/backup.sh to enable the timer
  4. add a key to ~/.ssh/authorized_keys, re-run setup/harden.sh to kill password auth
EOF
}

parse_common_args "$@"
require_root "$@"
main
