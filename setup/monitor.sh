#!/usr/bin/env bash
# monitor.sh — Prometheus node_exporter for host metrics.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: monitor.sh [--dry-run] [--help]

Installs prometheus-node-exporter (Debian package, ~15 MB resident) and
enables it on :9100.

Exposure: the exporter binds 0.0.0.0, but the nftables ruleset from
harden.sh drops inbound traffic on every interface except tailscale0. The
practical result is that metrics are reachable over the tailnet and nowhere
else. If you skip harden.sh, port 9100 is world-readable — firewall it.

Scrape it from a Prometheus elsewhere:

    - job_name: sbc
      static_configs:
        - targets: ['<tailscale-name>:9100']

Idempotent. Safe to re-run.
EOF
}

main() {
	require_apt_systemd
	log "installing node_exporter"

	apt_install prometheus-node-exporter
	enable_now prometheus-node-exporter.service

	if [ "$DRY_RUN" != 1 ] && ! nft list table inet filter >/dev/null 2>&1; then
		warn "no nftables ruleset loaded — :9100 is exposed on every interface"
		warn "run setup/harden.sh, or firewall port 9100 yourself"
	fi

	ok "node_exporter listening on :9100"
}

parse_common_args "$@"
require_root "$@"
main
