#!/usr/bin/env bash
# wizard.sh — one interactive pass over every other script: provision, install
# apps, strip the desktop. bootstrap.sh is the unattended path; this is the
# "walk me through it" path.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: wizard.sh [--dry-run] [--help]

Interactive front end to every script in this repo. Asks what to provision,
what to install and what to remove, collects the settings each part needs,
shows you the whole plan, and only then touches anything.

    1. provision   base, harden, tailscale, podman, shell, monitor, backup
    2. apps        dfs (file host), navidrome (music server)
    3. removal     purge an XFCE desktop off a headless box

Nothing happens until you confirm the summary. Answer with Enter to take the
default shown in [brackets].

Settings you supply here (Tailscale auth key, restic repository, dfs public
address) are written to the config files the stages read — but only when those
files do not exist yet: an existing config is yours, and is never overwritten.

Wants a terminal. For unattended runs use bootstrap.sh + environment variables:

    SKIP="tailscale monitor" ./setup/bootstrap.sh
    APPS=navidrome ./setup/apps.sh

Same guarantees as everything else here: --dry-run rehearses, every stage is
idempotent, replaced files are backed up.
EOF
}

STAGES=(base harden tailscale podman shell monitor backup)

# --- prompts ----------------------------------------------------------------
# Written to stderr, read from the terminal, so a plan printed to stdout can
# still be piped somewhere without the questions landing in it.

# ask_yn QUESTION DEFAULT(y|n) — true when the answer is yes.
ask_yn() {
	local q="$1" def="$2" reply hint='[y/N]'
	if [ "$def" = y ]; then hint='[Y/n]'; fi
	printf '  %s %s ' "$q" "$hint" >&2
	read -r reply
	if [ -z "$reply" ]; then reply="$def"; fi
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

# ask_val PROMPT DEFAULT — echoes the answer (or the default on Enter).
ask_val() {
	local p="$1" def="${2:-}" reply
	if [ -n "$def" ]; then
		printf '  %s [%s]: ' "$p" "$def" >&2
	else
		printf '  %s [none]: ' "$p" >&2
	fi
	read -r reply
	printf '%s' "${reply:-$def}"
}

# ask_secret PROMPT — same, but does not echo what is typed.
ask_secret() {
	local reply
	printf '  %s [none]: ' "$1" >&2
	read -rs reply
	printf '\n' >&2
	printf '%s' "$reply"
}

section() { printf '\n%s── %s ──%s\n' "$C_B" "$1" "$C_0" >&2; }

# Seed a config file a stage will later read. Never clobbers: an existing file
# holds the operator's own decisions (and, for restic, a live repository).
preseed() {
	local dest="$1" mode="$2"
	if [ -e "$dest" ]; then
		warn "$dest already exists — keeping it, your answer was not written"
		cat >/dev/null
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		warn "[dry] would create $dest (mode $mode)"
		cat >/dev/null
		return 0
	fi
	local tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	install -D -m "$mode" "$tmp" "$dest"
	rm -f "$tmp"
	ok "created $dest"
}

# --- interview --------------------------------------------------------------
WANT=()          # stage names to run
APPS_WANTED=()   # app names for apps.sh
REMOVE_XFCE=0
WANT_MEDIA=0
TS_KEY=''
RESTIC_REPO=''
DFS_PUB=''
ND_MUSIC=''
MEDIA_ID=''
MEDIA_AT=''
MEDIA_READONLY=0
RICH=0

interview() {
	section "provision"
	printf '  Each stage is independent and safe to re-run.\n' >&2
	local s
	for s in "${STAGES[@]}"; do
		if ask_yn "run $s?" y; then
			WANT+=("$s")
		fi
	done

	if want tailscale; then
		section "tailscale"
		printf '  An auth key joins the tailnet without a browser. Leave empty to\n' >&2
		printf '  run "sudo tailscale up" yourself later.\n' >&2
		TS_KEY="$(ask_secret 'tailscale auth key')"
	fi

	if want shell; then
		section "shell"
		printf '  Rich mode adds starship + atuin. They are not apt packages, so it\n' >&2
		printf '  downloads and runs their upstream installers. The default is lean\n' >&2
		printf '  and works offline.\n' >&2
		if ask_yn 'install starship + atuin (SHELL_RICH)?' n; then
			RICH=1
		fi
	fi

	if want backup; then
		section "backup"
		printf '  The backup timer stays disabled until a restic repository is set.\n' >&2
		printf '  Examples: sftp:user@nas:/backups/sbc  |  /mnt/usb/restic\n' >&2
		RESTIC_REPO="$(ask_val 'restic repository')"
	fi

	section "media"
	printf '  Without a desktop, nothing mounts a USB stick when you plug it in.\n' >&2
	printf '  This installs the udev + systemd rule that does, and can pin one\n' >&2
	printf '  drive to a fixed path for a service to read.\n' >&2
	if ask_yn 'set up USB media mounting?' n; then
		WANT_MEDIA=1
		lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID >&2 || true
		printf '  Leave the UUID empty for hotplug only (mounts under /media).\n' >&2
		MEDIA_ID="$(ask_val 'UUID of a drive to pin')"
		if [ -n "$MEDIA_ID" ]; then
			MEDIA_AT="$(ask_val 'mount it at' /srv/music)"
			if ask_yn 'mount it read-only (right for a library a service only reads)?' y; then
				MEDIA_READONLY=1
			fi
		fi
	fi

	section "apps"
	if ask_yn 'install dfs (encrypted file host, web UI)?' n; then
		APPS_WANTED+=(dfs)
		printf '  dfs stays disabled until it knows the address users reach it at;\n' >&2
		printf '  that address is also baked into its self-signed certificate.\n' >&2
		printf '  A Tailscale IP is a fine answer.\n' >&2
		DFS_PUB="$(ask_val 'dfs public host:port')"
	fi
	if ask_yn 'install navidrome (music server, Subsonic API)?' n; then
		APPS_WANTED+=(navidrome)
		ND_MUSIC="$(ask_val 'music library path' /srv/music)"
	fi

	section "removal"
	printf '  Purging XFCE frees a few hundred MB of RAM on a headless box. It is\n' >&2
	printf '  destructive: purge takes package config with it, and there is no undo.\n' >&2
	printf '  The remover asks again, and refuses to run inside a graphical session.\n' >&2
	if ask_yn 'purge the XFCE desktop?' n; then
		REMOVE_XFCE=1
	fi
}

want() {
	local s
	for s in ${WANT[@]+"${WANT[@]}"}; do
		if [ "$s" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

# --- plan -------------------------------------------------------------------
summary() {
	section "plan"
	if [ "${#WANT[@]}" -eq 0 ]; then
		printf '  stages:    (none)\n' >&2
	else
		printf '  stages:    %s\n' "${WANT[*]}"  >&2
	fi
	printf '  apps:      %s\n' "${APPS_WANTED[*]:-(none)}" >&2
	printf '  media:     %s\n' "$([ "$WANT_MEDIA" = 1 ] && printf 'hotplug%s' "${MEDIA_ID:+ + pin $MEDIA_ID at $MEDIA_AT}" || printf '(none)')" >&2
	printf '  remove:    %s\n' "$([ "$REMOVE_XFCE" = 1 ] && printf 'xfce' || printf '(nothing)')" >&2
	printf '  shell:     %s\n' "$([ "$RICH" = 1 ] && printf 'rich (starship + atuin)' || printf 'lean')" >&2
	printf '  tailscale: %s\n' "$([ -n "$TS_KEY" ] && printf 'join with auth key' || printf 'install only, join later')" >&2
	printf '  restic:    %s\n' "${RESTIC_REPO:-(unset — timer stays off)}" >&2
	printf '  dfs:       %s\n' "${DFS_PUB:-(unset — service stays off)}" >&2
	printf '  music:     %s\n' "${ND_MUSIC:-(n/a)}" >&2
	if [ "$DRY_RUN" = 1 ]; then
		warn "dry run: every step below prints what it would do and changes nothing"
	fi
}

# --- execution --------------------------------------------------------------
apply() {
	local args=() s
	if [ "$DRY_RUN" = 1 ]; then
		args+=(--dry-run)
	fi

	# Settings become config files *before* the stage that reads them runs, so
	# the stage sees a configured box and enables what it would otherwise leave
	# disabled.
	if [ -n "$RESTIC_REPO" ]; then
		preseed /etc/restic/env 0600 <<EOF
# Managed by steves-sbc-setup (setup/wizard.sh) — edit freely, never overwritten.
RESTIC_REPOSITORY=$RESTIC_REPO
RESTIC_PASSWORD_FILE=/etc/restic/password
RESTIC_CACHE_DIR=/var/cache/restic
EOF
	fi
	if [ -n "$DFS_PUB" ]; then
		preseed /etc/dfs/env 0644 <<EOF
# Managed by steves-sbc-setup (setup/wizard.sh) — edit freely, never overwritten.
DFS_ADDR=:8443
DFS_PUBLIC=$DFS_PUB
DFS_OPTS=
EOF
	fi

	# Children run as root already (we re-exec'd), so plain exported variables
	# reach them — no SUDO_KEEP dance needed here.
	export SHELL_RICH="$RICH"
	if [ -n "$TS_KEY" ]; then
		export TS_AUTHKEY="$TS_KEY"
	fi
	if [ -n "$ND_MUSIC" ]; then
		export NAVIDROME_MUSIC="$ND_MUSIC"
	fi

	for s in ${WANT[@]+"${WANT[@]}"}; do
		log "──── $s ────"
		"$SELF_DIR/$s.sh" ${args[@]+"${args[@]}"}
	done

	# Media before apps: navidrome's library should already be mounted when the
	# scanner first runs, or it indexes an empty folder.
	if [ "$WANT_MEDIA" = 1 ]; then
		log "──── media ────"
		MEDIA_UUID="$MEDIA_ID" MEDIA_MOUNT="${MEDIA_AT:-/srv/music}" MEDIA_RO="$MEDIA_READONLY" \
			"$SELF_DIR/media.sh" ${args[@]+"${args[@]}"}
	fi

	if [ "${#APPS_WANTED[@]}" -gt 0 ]; then
		log "──── apps ────"
		APPS="${APPS_WANTED[*]}" "$SELF_DIR/apps.sh" ${args[@]+"${args[@]}"}
	fi

	# Deliberately NOT passing XFCE_YES: the remover asks for itself and refuses
	# inside a graphical session. One "yes" here should not disarm both guards.
	if [ "$REMOVE_XFCE" = 1 ]; then
		log "──── remove-xfce ────"
		"$SELF_DIR/remove-xfce.sh" ${args[@]+"${args[@]}"}
	fi
}

main() {
	require_apt_systemd
	[ -t 0 ] || die "wizard needs a terminal — for unattended runs use bootstrap.sh"

	printf '\n%ssteves-sbc-setup%s — interactive setup. Nothing is applied until you confirm.\n' \
		"$C_G" "$C_0" >&2

	interview
	summary

	printf '\n' >&2
	if ! ask_yn 'apply this plan?' y; then
		die "aborted — nothing was changed"
	fi

	apply

	ok "wizard complete"
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi
	cat >&2 <<'EOF'

Left for you:
  * sudo cat /etc/restic/password   — store it off-box, or the backups are lost
  * add an SSH key, then re-run setup/harden.sh to switch password auth off
  * navidrome: load http://<host>:4533/ and claim the admin account
EOF
}

parse_common_args "$@"
require_root "$@"
main
