#!/usr/bin/env bash
# base.sh — core provisioning: essential packages, time sync, zram, auto-updates.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: base.sh [--dry-run] [--help]

Core provisioning for an SBC/server:
  * essential packages (curl, ca-certificates, gnupg, chrony, nftables)
  * chrony for time sync (SBCs usually have no RTC battery)
  * zram compressed swap, sized at 50% of RAM with zstd
  * unattended-upgrades for automatic security patches

Idempotent. Safe to re-run.
EOF
}

# zram gives a 2 GB Pinebook meaningful headroom: zstd compresses typical
# anonymous pages ~3:1, so 50% of RAM as zram nets more usable memory than it
# costs, and it never touches the eMMC/SD card.
setup_zram() {
	log "configuring zram swap"
	apt_install zram-tools
	install_file /etc/default/zramswap <<'EOF'
# Managed by steves-sbc-setup (setup/base.sh)
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
	enable_now zramswap.service
}

# Unattended security upgrades only; nothing that could reboot into a broken
# kernel unprompted.
setup_auto_upgrades() {
	log "enabling unattended security upgrades"
	apt_install unattended-upgrades
	install_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Managed by steves-sbc-setup (setup/base.sh)
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
	enable_now unattended-upgrades.service
}

main() {
	require_apt_systemd
	log "base provisioning on $(arch)"

	apt_install ca-certificates curl gnupg chrony

	# SBCs typically lack a battery-backed RTC; without NTP the clock starts at
	# epoch and TLS certificate validation fails on every outbound request.
	enable_now chrony.service

	setup_zram
	setup_auto_upgrades

	ok "base provisioning complete"
}

parse_common_args "$@"
require_root "$@"
main
