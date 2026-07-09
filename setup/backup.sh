#!/usr/bin/env bash
# backup.sh — encrypted, deduplicated restic backups on a systemd timer.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: backup.sh [--dry-run] [--help]

Installs restic and a daily backup timer.

Config lives in /etc/restic:
  env        repository URL and credentials (mode 0600)
  password   repository encryption key, generated once if absent (mode 0600)
  paths      what to back up   (default: /etc /home)
  excludes   what to skip      (caches, VCS objects, container storage)

The timer stays DISABLED until you set RESTIC_REPOSITORY in /etc/restic/env,
because a backup job pointed at nothing is worse than no backup job at all.
Re-run this script afterwards to enable it.

Retention: 7 daily, 4 weekly, 6 monthly snapshots (pruned after each run).

Idempotent. Safe to re-run. Existing config files are never overwritten.
EOF
}

ETC=/etc/restic
ENV_FILE="$ETC/env"
PW_FILE="$ETC/password"

# Config files here hold secrets and user intent, so unlike install_file this
# never clobbers or "backs up" an existing file.
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

write_config() {
	run install -d -m 0700 "$ETC"

	create_if_absent "$ENV_FILE" 0600 <<'EOF'
# Managed by steves-sbc-setup (setup/backup.sh) — edit freely, never overwritten.
# Examples:
#   RESTIC_REPOSITORY=sftp:user@nas:/backups/sbc
#   RESTIC_REPOSITORY=s3:s3.amazonaws.com/my-bucket
#   RESTIC_REPOSITORY=/mnt/usb/restic
RESTIC_REPOSITORY=
RESTIC_PASSWORD_FILE=/etc/restic/password
RESTIC_CACHE_DIR=/var/cache/restic
EOF

	if [ ! -e "$PW_FILE" ] && [ "$DRY_RUN" != 1 ]; then
		head -c 32 /dev/urandom | base64 | create_if_absent "$PW_FILE" 0600
		cat >&2 <<EOF

  ============================ IMPORTANT ============================
  A new restic encryption key was generated at $PW_FILE.

  This key is the ONLY way to decrypt your backups. If the SBC's disk
  fails and you have not stored a copy of this key somewhere else, the
  backups are permanently unrecoverable.

  Copy it off this machine now, into a password manager:

      sudo cat $PW_FILE

  ==================================================================

EOF
	else
		create_if_absent "$PW_FILE" 0600 </dev/null
	fi

	create_if_absent "$ETC/paths" 0644 <<'EOF'
/etc
/home
EOF

	create_if_absent "$ETC/excludes" 0644 <<'EOF'
**/.cache
**/node_modules
**/.git
/home/*/.local/share/containers
/var/cache
EOF
}

write_units() {
	# ProtectSystem=full (not strict) so a repo on /mnt or /srv still works.
	# Nice/idle IO keep a daily prune from stalling a single-core SBC.
	install_file /etc/systemd/system/restic-backup.service <<'EOF'
# Managed by steves-sbc-setup (setup/backup.sh)
[Unit]
Description=restic backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
CacheDirectory=restic
Nice=19
IOSchedulingClass=idle
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only

# Succeeds once, no-ops (nonzero) forever after; the '-' makes that non-fatal.
ExecStartPre=-/usr/bin/restic init
ExecStart=/usr/bin/restic backup --files-from /etc/restic/paths --exclude-file /etc/restic/excludes
ExecStartPost=/usr/bin/restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
EOF

	install_file /etc/systemd/system/restic-backup.timer <<'EOF'
# Managed by steves-sbc-setup (setup/backup.sh)
[Unit]
Description=daily restic backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

	run systemctl daemon-reload
}

# Grep rather than source: the env file is operator-editable, and sourcing it
# would execute whatever ended up in there.
repo_configured() {
	[ -r "$ENV_FILE" ] || return 1
	grep -qE '^[[:space:]]*RESTIC_REPOSITORY=[^[:space:]]' "$ENV_FILE"
}

main() {
	require_apt_systemd
	apt_install restic
	write_config
	write_units

	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] timer left untouched"
	elif repo_configured; then
		enable_now restic-backup.timer
		ok "backup timer enabled — next run: $(systemctl show -p NextElapseUSecRealtime --value restic-backup.timer 2>/dev/null || echo daily)"
	else
		warn "RESTIC_REPOSITORY is empty in $ENV_FILE — timer NOT enabled"
		warn "set it, then re-run: sudo setup/backup.sh"
	fi

	ok "restic configured"
}

parse_common_args "$@"
require_root "$@"
main
