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

Installs the self-hosted apps listed in APPS (default: dfs navidrome).

    dfs        steves-domainless-filehosting — encrypted-at-rest file host with
               accounts, a web UI and public share links. Single static Go
               binary, stdlib only. Built from source into /usr/local/bin/dfs,
               run by a system user 'dfs' under systemd, data in /var/lib/dfs.

    navidrome  music server with a web player, Subsonic API (so any Subsonic
               app on a phone works). Installed from the upstream .deb —
               checksum-verified — because it needs no compiling.

dfs config lives in /etc/dfs/env (never overwritten):
  DFS_ADDR     listen address                 (default :8443)
  DFS_PUBLIC   host:port advertised to users, and baked into the self-signed
               TLS cert. REQUIRED — the service stays DISABLED until it is set,
               because a file host with no reachable name serves nobody.
  DFS_OPTS     extra flags, e.g. --http for a trusted LAN

After enabling, create accounts as root:
    sudo -u dfs DFS_PASSWORD='…' dfs useradd alice --data /var/lib/dfs

navidrome knobs (env, at install time):
  NAVIDROME_VERSION   release tag to pin, e.g. v0.63.2 (default: latest)
  NAVIDROME_MUSIC     music library path     (default /srv/music)
  NAVIDROME_PORT      listen port            (default 4533)
Its first visitor creates the admin account, so reach it before anyone else can.

harden.sh's firewall opens neither port, so both are reachable over tailscale0
only. That is the intended default; open a port deliberately if you want it on
the LAN or the public internet.

Installing needs the network (apt, git clone + Go toolchain, GitHub release).

Idempotent. Safe to re-run: dfs rebuilds only when the source commit changed,
navidrome reinstalls only when the target version differs.
EOF
}

APPS="${APPS:-dfs navidrome}"

DFS_REPO="${DFS_REPO:-https://github.com/steve-berlin/steves-domainless-filehosting.git}"
DFS_REF="${DFS_REF:-main}"
DFS_SRC=/usr/local/src/steves-domainless-filehosting
DFS_BIN=/usr/local/bin/dfs
DFS_DATA=/var/lib/dfs
DFS_ETC=/etc/dfs
DFS_ENV="$DFS_ETC/env"
DFS_STAMP=/usr/local/src/.dfs-built

ND_REPO=navidrome/navidrome
ND_VERSION="${NAVIDROME_VERSION:-latest}"
ND_MUSIC="${NAVIDROME_MUSIC:-/srv/music}"
ND_PORT="${NAVIDROME_PORT:-4533}"
ND_CONF=/etc/navidrome/navidrome.toml

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

# --- the Go toolchain -------------------------------------------------------
# dfs's go.mod pins a newer language version than Debian ships. Go >= 1.21 solves
# that itself (GOTOOLCHAIN=auto downloads the exact toolchain go.mod asks for),
# but bookworm ships 1.19, which has neither GOTOOLCHAIN nor the `go -C` flag and
# simply refuses to build. So: use the distro Go when it is new enough, and
# otherwise install the upstream tarball into /usr/local/go.
GO_MIN=1.21
GO_PREFIX=/usr/local/go

go_cmd() {
	if [ -x "$GO_PREFIX/bin/go" ]; then
		printf '%s' "$GO_PREFIX/bin/go"
	else
		command -v go 2>/dev/null || true
	fi
}

# True when a Go new enough to bootstrap its own toolchain is on the box.
go_usable() {
	local g v
	g="$(go_cmd)"
	[ -n "$g" ] || return 1
	v="$("$g" env GOVERSION 2>/dev/null | sed 's/^go//')"
	[ -n "$v" ] || return 1
	dpkg --compare-versions "$v" ge "$GO_MIN"
}

# Go's own arch names, which are not Debian's.
go_asset_arch() {
	case "$(arch)" in
		amd64) printf 'amd64' ;;
		arm64) printf 'arm64' ;;
		armhf) printf 'armv6l' ;;
		i386)  printf '386' ;;
		*)     die "no upstream Go build for architecture $(arch)" ;;
	esac
}

install_go_upstream() {
	local ver tar sum tmp
	ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
	[ -n "$ver" ] || die "could not resolve the latest Go version"
	tar="${ver}.linux-$(go_asset_arch).tar.gz"

	log "no Go >= $GO_MIN on the box — installing $ver into $GO_PREFIX"
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would download, verify and unpack $tar"
		return 0
	fi

	# The .sha256 URLs serve HTML, so take the hash from the release index.
	sum="$(curl -fsSL 'https://go.dev/dl/?mode=json' |
		grep -A4 "\"filename\": \"$tar\"" |
		sed -n 's/.*"sha256": "\([0-9a-f]\{64\}\)".*/\1/p' | head -n1)"
	[ -n "$sum" ] || die "no published sha256 for $tar"

	tmp="$(mktemp -d)"
	curl -fsSL --retry 3 -o "$tmp/$tar" "https://go.dev/dl/$tar"
	printf '%s  %s\n' "$sum" "$tmp/$tar" | sha256sum -c - ||
		die "checksum mismatch for $tar — refusing to install"
	rm -rf "$GO_PREFIX"
	tar -C /usr/local -xzf "$tmp/$tar"
	rm -rf "$tmp"
	ok "installed $ver at $GO_PREFIX"
}

ensure_go() {
	if go_usable; then
		ok "Go toolchain usable: $(go_cmd)"
		return 0
	fi
	apt_install golang-go
	if go_usable; then
		ok "distro Go is new enough: $(go_cmd)"
		return 0
	fi
	install_go_upstream
}

# GOTOOLCHAIN=auto lets Go fetch the toolchain go.mod pins. -p 2 caps compiler
# parallelism — the default (one job per core) can OOM a 2 GB board. The build
# runs in a subshell that cd's into the source: `go -C` would be shorter but
# needs Go >= 1.20, and the whole point here is to survive an older one.
dfs_build() {
	local commit="$1" go
	if [ -x "$DFS_BIN" ] && [ -f "$DFS_STAMP" ] && [ "$(cat "$DFS_STAMP")" = "$commit" ] && [ -n "$commit" ]; then
		ok "dfs already built at $commit"
		return 0
	fi
	go="$(go_cmd)"
	log "building dfs (this takes a few minutes on an SBC)"
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would build: cd $DFS_SRC && ${go:-go} build -p 2 -trimpath -o $DFS_BIN ."
		return 0
	fi
	[ -n "$go" ] || die "no Go toolchain found after ensure_go"
	( cd "$DFS_SRC" && env GOTOOLCHAIN=auto GOCACHE=/var/cache/go-build GOPATH=/var/lib/go HOME=/root \
		"$go" build -p 2 -trimpath -ldflags '-s -w' -o "$DFS_BIN" . )
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
	apt_install git curl ca-certificates
	ensure_go
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

	firewall_note dfs
}

# harden.sh's ruleset opens no app ports, so an app is tailnet-only by default.
# Without that ruleset it is on every interface instead — worth saying out loud.
firewall_note() {
	if ! nft list ruleset >/dev/null 2>&1 || [ -z "$(nft list ruleset 2>/dev/null)" ]; then
		warn "no nftables ruleset loaded — $1 would be exposed on every interface; run setup/harden.sh"
	else
		ok "firewall present — $1 reachable over tailscale0 only until you open its port"
	fi
}

# --- navidrome --------------------------------------------------------------
# Upstream ships a .deb, so there is nothing to compile: Navidrome bundles a
# prebuilt web UI, and building that would drag in Node on a 2 GB board.

# Debian arch -> the arch string in the release asset names.
nd_asset_arch() {
	case "$(arch)" in
		amd64) printf 'amd64' ;;
		arm64) printf 'arm64' ;;
		armhf) printf 'armv7' ;;
		i386)  printf '386' ;;
		*)     die "no navidrome release for architecture $(arch)" ;;
	esac
}

# Resolve "latest" to a real tag once, so the version we check, download and
# record is the same one even if upstream publishes mid-run.
nd_resolve_version() {
	if [ "$ND_VERSION" != latest ]; then
		printf '%s' "$ND_VERSION"
		return 0
	fi
	curl -fsSL "https://api.github.com/repos/$ND_REPO/releases/latest" |
		sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
		head -n1
}

# Download the .deb and verify it against the release's checksums.txt. An
# unverified binary running as a service is not something to shrug at.
nd_fetch_deb() {
	local tag="$1" ver="$2" dir="$3" deb="$4"
	local base="https://github.com/$ND_REPO/releases/download/$tag"
	run curl -fsSL --retry 3 -o "$dir/$deb" "$base/$deb"
	run curl -fsSL --retry 3 -o "$dir/navidrome_checksums.txt" "$base/navidrome_checksums.txt"
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would verify sha256 of $deb"
		return 0
	fi
	( cd "$dir" && grep -F " $deb" navidrome_checksums.txt | sha256sum -c - ) ||
		die "checksum mismatch for $deb — refusing to install"
	ok "checksum verified: $deb ($ver)"
}

nd_installed_version() {
	dpkg-query -W -f='${Version}' navidrome 2>/dev/null || true
}

nd_config() {
	# Navidrome's own .deb ships this path as a conffile; install_file backs up
	# whatever is there before writing, so an upstream sample is never lost.
	install_file "$ND_CONF" 0640 <<EOF
# Managed by steves-sbc-setup (setup/apps.sh)
MusicFolder = "$ND_MUSIC"
DataFolder = "/var/lib/navidrome"
Port = $ND_PORT
Address = "0.0.0.0"
LogLevel = "info"

# A full rescan is expensive on SD storage; watch the folder instead and sweep
# once a day.
ScanSchedule = "@every 24h"

# Caches live on eMMC/SD. Keep them small on purpose.
TranscodingCacheSize = "50MB"
ImageCacheSize = "100MB"
EOF
	run chgrp navidrome "$ND_CONF"

	# The library is yours, not the service's: owned by the box's human, and
	# navidrome only ever reads it (world-readable, mode 0755).
	local owner
	owner="$(target_user)"
	if [ -n "$owner" ]; then
		run install -d -m 0755 -o "$owner" -g "$(id -gn "$owner")" "$ND_MUSIC"
	else
		run install -d -m 0755 "$ND_MUSIC"
	fi
}

install_navidrome() {
	local tag ver aarch deb tmp
	apt_install curl ca-certificates

	tag="$(nd_resolve_version)"
	[ -n "$tag" ] || die "could not resolve the latest navidrome release"
	ver="${tag#v}"
	aarch="$(nd_asset_arch)"
	deb="navidrome_${ver}_linux_${aarch}.deb"

	if [ "$(nd_installed_version)" = "$ver" ]; then
		ok "navidrome $ver already installed"
	else
		log "installing navidrome $ver ($aarch)"
		tmp="$(mktemp -d)"
		nd_fetch_deb "$tag" "$ver" "$tmp" "$deb"
		# apt, not dpkg: it pulls the .deb's dependencies (ffmpeg, etc).
		run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$deb"
		rm -rf "$tmp"
	fi

	nd_config
	run systemctl daemon-reload
	enable_now navidrome.service
	firewall_note navidrome

	warn "navidrome: the FIRST visitor to http://<host>:$ND_PORT/ creates the admin account — claim it now"
	warn "drop music into $ND_MUSIC; it is rescanned daily (or on change)"
}

main() {
	require_apt_systemd

	local app
	for app in $APPS; do
		case "$app" in
			dfs)       log "──── dfs ────"; install_dfs ;;
			navidrome) log "──── navidrome ────"; install_navidrome ;;
			*)         die "unknown app: $app" ;;
		esac
	done

	ok "apps installed: $APPS"
}

parse_common_args "$@"
require_root "$@"
main
