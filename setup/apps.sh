#!/usr/bin/env bash
# apps.sh — optional self-hosted apps. Not part of bootstrap: opt-in only.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: apps.sh [--dry-run] [--help]

Installs the self-hosted apps listed in APPS (default: dfs).

    dfs   steves-domainless-filehosting — encrypted-at-rest file host with
          accounts, a web UI and public share links. Single static Go binary,
          stdlib only. Built from source into /usr/local/bin/dfs, run by a
          system user 'dfs' under systemd, data in /var/lib/dfs.

Config lives in /etc/dfs/env (never overwritten):
  DFS_ADDR     listen address                 (default :8443)
  DFS_PUBLIC   host:port advertised to users, and baked into the self-signed
               TLS cert. REQUIRED — the service stays DISABLED until it is set,
               because a file host with no reachable name serves nobody.
  DFS_OPTS     extra flags, e.g. --http for a trusted LAN

After enabling, create accounts as root:
    sudo -u dfs DFS_PASSWORD='…' dfs useradd alice --data /var/lib/dfs

harden.sh's firewall does not open DFS_ADDR, so the host is reachable over
tailscale0 only. That is the intended default; open the port deliberately if
you want it on the LAN or the public internet.

Building needs the network (apt + git clone + Go module/toolchain fetch).

Idempotent. Safe to re-run: it rebuilds only when the source commit changed.
EOF
}

APPS="${APPS:-dfs}"

DFS_REPO="${DFS_REPO:-https://github.com/steve-berlin/steves-domainless-filehosting.git}"
DFS_REF="${DFS_REF:-main}"
DFS_SRC=/usr/local/src/steves-domainless-filehosting
DFS_BIN=/usr/local/bin/dfs
DFS_DATA=/var/lib/dfs
DFS_ETC=/etc/dfs
DFS_ENV="$DFS_ETC/env"
DFS_STAMP=/usr/local/src/.dfs-built

# Config holds operator intent, so — like backup.sh — this never clobbers.
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

# Clone once, fast-forward after. Echoes the checked-out commit (empty on dry
# runs, where the tree may not exist yet).
dfs_sync_source() {
	if [ -d "$DFS_SRC/.git" ]; then
		run git -C "$DFS_SRC" fetch --depth 1 origin "$DFS_REF"
		run git -C "$DFS_SRC" checkout -q FETCH_HEAD
	else
		run git clone --depth 1 --branch "$DFS_REF" "$DFS_REPO" "$DFS_SRC"
	fi
	git -C "$DFS_SRC" rev-parse HEAD 2>/dev/null || true
}

# Build with the distro Go. dfs pins a newer language version in go.mod than
# Debian ships, so GOTOOLCHAIN=auto is load-bearing: it lets the toolchain fetch
# the exact Go it needs instead of failing. -p 2 caps compiler parallelism —
# the default (one job per core) can OOM a 2 GB board.
dfs_build() {
	local commit="$1"
	if [ -x "$DFS_BIN" ] && [ -f "$DFS_STAMP" ] && [ "$(cat "$DFS_STAMP")" = "$commit" ] && [ -n "$commit" ]; then
		ok "dfs already built at $commit"
		return 0
	fi
	log "building dfs (this takes a few minutes on an SBC)"
	run env GOTOOLCHAIN=auto GOCACHE=/var/cache/go-build GOPATH=/var/lib/go HOME=/root \
		go -C "$DFS_SRC" build -p 2 -trimpath -ldflags '-s -w' -o "$DFS_BIN" .
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi
	printf '%s\n' "$commit" >"$DFS_STAMP"
	ok "built $DFS_BIN ($commit)"
}

dfs_account() {
	if id dfs >/dev/null 2>&1; then
		ok "system user 'dfs' exists"
	else
		run useradd --system --home-dir "$DFS_DATA" --shell /usr/sbin/nologin dfs
	fi
	# 0700: the data dir holds master.key and every user's ciphertext.
	run install -d -m 0700 -o dfs -g dfs "$DFS_DATA"
	run install -d -m 0755 "$DFS_ETC"
}

dfs_config() {
	create_if_absent "$DFS_ENV" 0644 <<'EOF'
# Managed by steves-sbc-setup (setup/apps.sh) — edit freely, never overwritten.
# DFS_PUBLIC is the host:port users type, and what the self-signed cert is
# issued for. Leave it empty and the service stays disabled on purpose.
#   DFS_PUBLIC=100.101.102.103:8443   (a Tailscale IP works fine)
DFS_ADDR=:8443
DFS_PUBLIC=
DFS_OPTS=
EOF
}

dfs_unit() {
	# ProtectSystem=strict + StateDirectory: the only writable path is
	# /var/lib/dfs. RestrictAddressFamilies keeps it to TCP/IP.
	install_file /etc/systemd/system/dfs.service <<EOF
# Managed by steves-sbc-setup (setup/apps.sh)
[Unit]
Description=dfs — domainless file host
Wants=network-online.target
After=network-online.target

[Service]
User=dfs
Group=dfs
EnvironmentFile=$DFS_ENV
StateDirectory=dfs
WorkingDirectory=$DFS_DATA
ExecStart=$DFS_BIN serve --data $DFS_DATA --addr \${DFS_ADDR} --public \${DFS_PUBLIC} \$DFS_OPTS
Restart=on-failure
RestartSec=5
Nice=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF
	run systemctl daemon-reload
}

# Grep rather than source: the env file is operator-editable, and sourcing it
# would execute whatever ended up in there.
dfs_configured() {
	[ -r "$DFS_ENV" ] || return 1
	grep -qE '^[[:space:]]*DFS_PUBLIC=[^[:space:]]' "$DFS_ENV"
}

install_dfs() {
	local commit
	apt_install git golang-go ca-certificates
	commit="$(dfs_sync_source)"
	dfs_build "$commit"
	dfs_account
	dfs_config
	dfs_unit

	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] dfs.service left untouched"
	elif dfs_configured; then
		enable_now dfs.service
		ok "dfs.service enabled"
	else
		warn "DFS_PUBLIC is empty in $DFS_ENV — dfs.service NOT enabled"
		warn "set it, then re-run: sudo setup/apps.sh"
	fi

	if ! nft list ruleset >/dev/null 2>&1 || [ -z "$(nft list ruleset 2>/dev/null)" ]; then
		warn "no nftables ruleset loaded — dfs would be exposed on every interface; run setup/harden.sh"
	else
		ok "firewall present — dfs reachable over tailscale0 only until you open its port"
	fi
}

main() {
	require_apt_systemd

	local app
	for app in $APPS; do
		case "$app" in
			dfs) log "──── dfs ────"; install_dfs ;;
			*)   die "unknown app: $app" ;;
		esac
	done

	ok "apps installed: $APPS"
}

parse_common_args "$@"
require_root "$@"
main
