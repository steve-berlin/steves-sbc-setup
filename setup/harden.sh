#!/usr/bin/env bash
# harden.sh — SSH lockdown, kernel sysctl tuning, nftables default-deny firewall.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: harden.sh [--dry-run] [--help]

Hardens the box in three layers:
  * sshd     — no root login, key-only auth, no X11 forwarding
  * sysctl   — network/kernel hardening plus BBR + zram-aware VM tuning
  * nftables — default-deny inbound; allows loopback, established, ICMP,
               SSH, and everything arriving on tailscale0

SSH SAFETY: password authentication is only disabled when an authorized_keys
file with at least one key already exists. Otherwise the lockdown is skipped
with a warning, so this script can never lock you out of your own box.
Override that guard with FORCE_SSH_KEYONLY=1 (you have been warned).

Idempotent. Safe to re-run. Every file it replaces is backed up first.
EOF
}

# --- ssh --------------------------------------------------------------------

# True when some account has a non-empty authorized_keys file. Without this,
# disabling password auth would strand the operator outside the box.
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

harden_ssh() {
	log "hardening sshd"

	# Own the dependency rather than assuming base.sh ran: every script here is
	# meant to be independently runnable.
	apt_install openssh-server
	if [ "$DRY_RUN" = 1 ] && [ ! -f /etc/ssh/sshd_config ]; then
		warn "[dry] openssh-server not installed — skipping sshd checks"
		return 0
	fi

	# Drop-ins require OpenSSH >= 8.2 *and* the Include line in the main config.
	# Debian/Ubuntu ship it, but a hand-edited sshd_config may have lost it, in
	# which case our file would be silently ignored — a dangerous no-op.
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
		die "/etc/ssh/sshd_config lacks an Include for sshd_config.d — add it, or this hardening would be silently ignored"
	fi

	local pw_auth='yes' note='# password auth LEFT ENABLED: no authorized_keys found at install time'
	if has_ssh_key || [ "${FORCE_SSH_KEYONLY:-0}" = 1 ]; then
		pw_auth='no'
		note='# password auth disabled: key-based login verified'
	else
		warn "no authorized_keys found — leaving PasswordAuthentication enabled"
		warn "add a key, then re-run harden.sh to complete the lockdown"
	fi

	install_file /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<EOF
# Managed by steves-sbc-setup (setup/harden.sh)
$note
PermitRootLogin no
PasswordAuthentication $pw_auth
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
EOF

	# Never reload a config that fails validation; that bricks remote access.
	if [ "$DRY_RUN" != 1 ]; then
		sshd -t || die "sshd config validation failed — not reloading"
	fi
	enable_now ssh.service
	run systemctl reload ssh.service
}

# --- sysctl -----------------------------------------------------------------

sysctl_tuning() {
	log "applying sysctl tuning"

	# BBR + fq is a large, free throughput win on lossy links, but tcp_bbr is a
	# module on most SBC kernels and may not be built at all.
	local cc_lines=''
	if [ "$DRY_RUN" != 1 ]; then
		modprobe tcp_bbr 2>/dev/null || true
	fi
	if [ "$DRY_RUN" = 1 ] || grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		cc_lines=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
		install_file /etc/modules-load.d/bbr.conf <<'EOF'
# Managed by steves-sbc-setup (setup/harden.sh)
tcp_bbr
EOF
	else
		warn "kernel has no BBR support — leaving congestion control at default"
	fi

	install_file /etc/sysctl.d/99-sbc.conf <<EOF
# Managed by steves-sbc-setup (setup/harden.sh)

# --- memory: tuned for zram, not for a disk-backed swapfile ---
# Swapping to compressed RAM is cheap, so lean on it hard rather than evicting
# page cache. On flash storage this also avoids pointless write wear.
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# --- network performance ---
net.ipv4.tcp_fastopen = 3
$cc_lines

# --- network hardening ---
# rp_filter is LOOSE (2), not strict (1): Tailscale subnet routes and exit
# nodes create legitimately asymmetric paths that strict mode would drop.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# --- kernel hardening ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
	run sysctl --system
}

# --- firewall ---------------------------------------------------------------

setup_firewall() {
	log "installing nftables default-deny firewall"
	apt_install nftables

	# Rootless Podman uses pasta/slirp4netns rather than a bridge, so containers
	# need no forward rules here. Rootful Podman would.
	install_file /etc/nftables.conf 0644 <<'EOF'
#!/usr/sbin/nft -f
# Managed by steves-sbc-setup (setup/harden.sh)
flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;

		ct state established,related accept
		ct state invalid drop
		iif lo accept

		# Tailscale peers are already authenticated + encrypted by WireGuard.
		iifname "tailscale0" accept

		# ICMP: needed for path-MTU discovery, not just ping.
		meta l4proto icmp accept
		meta l4proto ipv6-icmp accept

		# DHCP client replies can arrive before conntrack has an entry.
		udp dport 68 accept

		tcp dport 22 accept
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF

	# Validate before enabling: a malformed ruleset that fails to load leaves
	# the box with no firewall, and one that loads wrong locks out SSH.
	if [ "$DRY_RUN" != 1 ]; then
		nft -c -f /etc/nftables.conf || die "nftables ruleset failed validation — not enabling"
	fi
	enable_now nftables.service
}

main() {
	require_apt_systemd
	harden_ssh
	sysctl_tuning
	setup_firewall
	ok "hardening complete"
}

parse_common_args "$@"
require_root "$@"
main
