#!/usr/bin/env bash
# shell.sh — zsh + tmux for a comfortable, disconnect-proof remote shell.
# Re-exec under bash if started with `sh script`: that bypasses the shebang, and
# pipefail / arrays / ${BASH_SOURCE} below are bashisms dash cannot run.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

usage() {
	cat <<'EOF'
usage: shell.sh [--dry-run] [--help]

Installs a lean interactive shell for the box's owner:
  * zsh with the two Debian plugin packages (syntax highlighting,
    autosuggestions) — no framework, no network fetches
  * tmux with a native, plugin-free config so a dropped SSH connection
    never kills a running job

Writes ~/.zshrc and ~/.tmux.conf owned by the target user, and switches that
user's login shell to zsh. Set SHELL_NO_CHSH=1 to skip the shell change.

SHELL_RICH=1 adds a starship prompt and atuin shell history. Unlike everything
else here these are NOT apt packages: each is downloaded from the internet and
run, so the rich path needs connectivity. The default (lean) path never fetches
anything and works offline.

The owner is taken from $SUDO_USER, or $TARGET_USER when running as root
directly.

Idempotent. Safe to re-run. Any dotfile it replaces is backed up first.
EOF
}

STARSHIP_URL=https://starship.rs/install.sh
ATUIN_URL=https://setup.atuin.sh

# SHELL_RICH extras. These are NOT apt packages — each is fetched from the
# internet and executed, so this path needs connectivity and trust in the
# upstream installers. The lean default path never calls this. Idempotent:
# skips whatever is already installed.
install_rich() {
	local u="$1"
	apt_install ca-certificates curl

	# starship: a single binary, installed system-wide into /usr/local/bin.
	if command -v starship >/dev/null 2>&1; then
		ok "starship already installed"
	else
		log "installing starship into /usr/local/bin (network fetch)"
		run sh -c "curl -fsSL $STARSHIP_URL | sh -s -- -y -b /usr/local/bin"
	fi

	# atuin: installed into the target user's home (~/.atuin), not root's.
	# --no-modify-path because our ~/.zshrc puts ~/.atuin/bin on PATH itself.
	# shellcheck disable=SC2016  # $HOME must expand in the user's sh, not here
	if runuser -u "$u" -- sh -c 'command -v atuin >/dev/null 2>&1 || [ -x "$HOME/.atuin/bin/atuin" ]'; then
		ok "atuin already installed for $u"
	else
		log "installing atuin for $u (network fetch)"
		run runuser -u "$u" -- sh -c "curl -fsSL $ATUIN_URL | sh -s -- --no-modify-path"
	fi
}

main() {
	require_apt_systemd

	local u home grp
	u="$(target_user)"
	[ -n "$u" ] || die "no unprivileged user found — run via sudo, or set TARGET_USER"
	id "$u" >/dev/null 2>&1 || die "user '$u' does not exist"
	home="$(getent passwd "$u" | cut -d: -f6)"
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		die "no home directory for '$u'"
	fi
	grp="$(id -gn "$u")"
	log "configuring zsh + tmux for '$u' ($home)"

	local rich=0
	if [ "${SHELL_RICH:-0}" = 1 ]; then
		rich=1
	fi

	apt_install zsh zsh-syntax-highlighting zsh-autosuggestions tmux
	if [ "$rich" = 1 ]; then
		install_rich "$u"
	fi

	# --- ~/.zshrc -----------------------------------------------------------
	# Lean by default: native zsh + apt plugins only, so first start is instant
	# and nothing phones home. SHELL_RICH=1 appends starship + atuin init lines,
	# each guarded so a missing binary never breaks the shell.
	{
		cat <<'EOF'
# ~/.zshrc — managed by steves-sbc-setup (setup/shell.sh)
# Lean interactive config for a headless box. Native zsh + apt plugins only.

# --- history ---
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE INC_APPEND_HISTORY

# --- completion (compinit -C skips the daily security scan: faster start on
#     slow storage, fine for a single-user box) ---
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
setopt AUTO_CD

bindkey -e   # emacs keys: what every SSH client expects by default

# --- prompt: git-aware, built from vcs_info so it needs no external binary ---
autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' (%b)'
precmd() { vcs_info }
setopt PROMPT_SUBST
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f%F{yellow}${vcs_info_msg_0_}%f%# '

# --- aliases ---
alias ll='ls -alh --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'

# --- plugins (Debian packages). syntax-highlighting must be sourced last: it
#     hooks the line editor and expects to wrap everything before it. ---
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
EOF
		if [ "$rich" = 1 ]; then
			cat <<'EOF'

# --- rich extras (SHELL_RICH): starship prompt + atuin history ---
# starship replaces the vcs_info prompt above. Both are guarded with `command
# -v`, so if a binary is missing the shell still starts (and falls back to the
# native prompt).
export PATH="$HOME/.atuin/bin:$HOME/.local/bin:$PATH"
command -v starship >/dev/null && eval "$(starship init zsh)"
command -v atuin >/dev/null && eval "$(atuin init zsh)"
EOF
		fi
	} | install_file "$home/.zshrc" 0644 "$u:$grp"

	# --- ~/.tmux.conf -------------------------------------------------------
	# Native config, zero plugins: the one feature that actually matters on a
	# server — a session that outlives a dropped SSH connection — is built into
	# tmux itself and needs nothing fetched.
	install_file "$home/.tmux.conf" 0644 "$u:$grp" <<'EOF'
# ~/.tmux.conf — managed by steves-sbc-setup (setup/shell.sh)
# Plugin-free: nothing to clone, nothing to break on a headless box.

# Prefix C-a — easier to reach than C-b over SSH.
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# screen-256color, not tmux-256color: it exists in the base terminfo on every
# minimal install, so colours work without pulling in ncurses-term.
set -g default-terminal "screen-256color"

set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10          # don't swallow Esc in vim over a slow link
set -g set-clipboard on

# Splits that keep the current directory; a reload key for quick edits.
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"

# vim-style pane movement.
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

set -g status-style 'bg=default fg=green'
set -g status-right '#H  %H:%M'
EOF

	# --- login shell --------------------------------------------------------
	local zsh_bin
	zsh_bin="$(command -v zsh || true)"
	if [ "${SHELL_NO_CHSH:-0}" = 1 ]; then
		warn "SHELL_NO_CHSH=1 — leaving login shell unchanged"
	elif [ -z "$zsh_bin" ]; then
		warn "zsh binary not found on PATH — not changing login shell"
	elif [ "$(getent passwd "$u" | cut -d: -f7)" = "$zsh_bin" ]; then
		ok "login shell already zsh for $u"
	else
		log "setting login shell to $zsh_bin for $u"
		run chsh -s "$zsh_bin" "$u"
	fi

	ok "shell environment ready for $u — log out and back in to use zsh"
}

parse_common_args "$@"
require_root "$@"
main
