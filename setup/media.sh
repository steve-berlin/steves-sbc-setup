#!/usr/bin/env bash
# media.sh — the thing a desktop does when you plug a USB stick in, minus the
# desktop: hotplugged filesystems get mounted under /media, and a named drive
# can be pinned to a fixed path for a service to read.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: media.sh [--dry-run] [--help]

Two separate things, both aimed at a box with no desktop:

  1. HOTPLUG. A udev rule hands any USB filesystem to systemd-mount, which
     mounts it at /media/<label> on first access and tears the mount down when
     the device disappears. Same end result as a file manager's auto-mount, no
     session, no udisks, no polkit.

  2. A PINNED DRIVE, for a service that needs a stable path (Navidrome reading
     a music library, say). Set MEDIA_UUID and it writes an /etc/fstab entry:

        MEDIA_UUID=1234-ABCD MEDIA_MOUNT=/srv/music sudo ./setup/media.sh

     MEDIA_MOUNT  where to mount it            (default /srv/music)
     MEDIA_RO=1   mount read-only — sensible for a library a service only reads
     MEDIA_USER   who owns the files on a filesystem that has no owners
                  (vfat/exfat/ntfs)            (default: the box's owner)

     The entry always carries `nofail`: without it, booting with the drive
     unplugged hangs a headless box waiting for a device that will never arrive.

Run with no MEDIA_UUID and it prints what is currently attached, then sets up
hotplug only.

Idempotent. Safe to re-run. /etc/fstab is backed up before it is touched.
EOF
}

HELPER=/usr/local/sbin/usb-automount
RULE=/etc/udev/rules.d/99-usb-automount.rules

MEDIA_MOUNT="${MEDIA_MOUNT:-/srv/music}"

# Filesystems a USB drive actually shows up with. exfatprogs/ntfs-3g are the
# two Debian does not install by default, and their absence looks like "the
# stick is broken" rather than "the driver is missing".
install_drivers() {
	apt_install exfatprogs ntfs-3g dosfstools udev
}

show_devices() {
	log "block devices seen right now:"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT >&2 || true
}

# --- 1. hotplug -------------------------------------------------------------
# udev cannot mount things itself (its mounts live in a private namespace and
# vanish), so it calls systemd-mount, which creates a transient .mount unit in
# the real namespace. --automount=yes means the filesystem is only really
# mounted on first access, and the unit is BindsTo= the device: pull the stick
# and systemd tears the mount down on its own.
install_hotplug() {
	local u uid gid
	u="$(target_user)"
	uid=0
	gid=0
	if [ -n "$u" ] && id "$u" >/dev/null 2>&1; then
		uid="$(id -u "$u")"
		gid="$(id -g "$u")"
	fi

	install_file "$HELPER" 0755 <<EOF
#!/bin/sh
# Managed by steves-sbc-setup (setup/media.sh). Called by udev on hotplug.
# \$1 is the device node, e.g. /dev/sda1.
set -eu
dev="\$1"

# blkid -o export prints TYPE=/LABEL=/UUID= as shell assignments.
eval "\$(blkid -o export "\$dev" 2>/dev/null)" || exit 0
[ -n "\${TYPE:-}" ] || exit 0

# Never touch the disk the system boots from.
case "\$TYPE" in
	swap|linux_raid_member|LVM2_member|crypto_LUKS) exit 0 ;;
esac

# Name the mountpoint after the label, falling back to the UUID. Anything
# outside [A-Za-z0-9._-] becomes an underscore: a label is user input, and it
# ends up in a path.
name="\${LABEL:-\${UUID:-\$(basename "\$dev")}}"
name="\$(printf '%s' "\$name" | tr -c 'A-Za-z0-9._-' '_')"

opts="nosuid,nodev,noatime"
case "\$TYPE" in
	vfat|exfat|ntfs) opts="\$opts,uid=$uid,gid=$gid,umask=0022" ;;
esac

exec systemd-mount --no-block --collect --automount=yes \\
	-o "\$opts" "\$dev" "/media/\$name"
EOF

	install_file "$RULE" 0644 <<EOF
# Managed by steves-sbc-setup (setup/media.sh)
# Only USB block devices that actually carry a filesystem, and only whole
# partitions — ID_FS_USAGE=="filesystem" excludes swap, RAID and LVM members.
ACTION=="add", SUBSYSTEM=="block", SUBSYSTEMS=="usb", ENV{ID_FS_USAGE}=="filesystem", RUN{program}+="$HELPER %E{DEVNAME}"
EOF

	run udevadm control --reload-rules
	ok "hotplug mounting active — plug a stick in and look under /media"
}

# --- 2. pinned drive --------------------------------------------------------
fstab_opts() {
	local fstype="$1" opts="nofail,x-systemd.device-timeout=5,nosuid,nodev,noatime"
	if [ "${MEDIA_RO:-0}" = 1 ]; then
		opts="$opts,ro"
	fi
	case "$fstype" in
		vfat|exfat|ntfs|ntfs3)
			local u uid gid
			u="${MEDIA_USER:-$(target_user)}"
			uid=0
			gid=0
			if [ -n "$u" ] && id "$u" >/dev/null 2>&1; then
				uid="$(id -u "$u")"
				gid="$(id -g "$u")"
			fi
			opts="$opts,uid=$uid,gid=$gid,umask=0022"
			;;
	esac
	printf '%s' "$opts"
}

pin_drive() {
	local uuid="$1" fstype line
	fstype="$(blkid -o value -s TYPE "/dev/disk/by-uuid/$uuid" 2>/dev/null || true)"
	[ -n "$fstype" ] || die "no filesystem with UUID $uuid is attached — plug it in, then re-run"

	if grep -qE "^[[:space:]]*UUID=${uuid}[[:space:]]" /etc/fstab; then
		ok "fstab already has an entry for UUID=$uuid — left alone"
	else
		line="UUID=$uuid $MEDIA_MOUNT $fstype $(fstab_opts "$fstype") 0 0"
		log "adding to /etc/fstab: $line"
		if [ "$DRY_RUN" = 1 ]; then
			warn "[dry] /etc/fstab not touched"
		else
			cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
			printf '\n# Managed by steves-sbc-setup (setup/media.sh)\n%s\n' "$line" >>/etc/fstab
			ok "backed up /etc/fstab, appended the entry"
		fi
	fi

	run install -d -m 0755 "$MEDIA_MOUNT"

	# A bad fstab line is a box that will not boot. Check before mounting, not
	# after rebooting.
	if [ "$DRY_RUN" != 1 ]; then
		findmnt --verify --verbose >/dev/null 2>&1 ||
			warn "findmnt --verify is unhappy with /etc/fstab — check it before rebooting"
	fi

	run systemctl daemon-reload
	if mountpoint -q "$MEDIA_MOUNT" 2>/dev/null; then
		ok "already mounted: $MEDIA_MOUNT"
	else
		run mount "$MEDIA_MOUNT"
	fi
	ok "UUID=$uuid mounted at $MEDIA_MOUNT ($fstype)"
}

main() {
	require_apt_systemd
	install_drivers
	show_devices
	install_hotplug

	if [ -n "${MEDIA_UUID:-}" ]; then
		pin_drive "$MEDIA_UUID"
	else
		warn "MEDIA_UUID not set — hotplug only, nothing pinned to a fixed path"
		warn "to pin one: MEDIA_UUID=<uuid from the table above> sudo setup/media.sh"
	fi

	ok "media ready"
}

parse_common_args "$@"
require_root "$@"
main
