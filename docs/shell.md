# `setup/shell.sh` explained

Plain-language walkthrough of the zsh + tmux stage. If you just want to use it,
the README is enough — this is the "why is it built this way" version.

## What it's for

Two comforts for a computer you only ever talk to over SSH:

- **zsh** — a nicer shell than the default. Tab-completion that shows a menu,
  suggestions from your history as you type, and colours that flag a typo before
  you hit Enter.
- **tmux** — a "screen saver for your work." Start a long job inside tmux, your
  wifi drops, the SSH connection dies — the job keeps running. Reconnect, run
  `tmux attach`, and you're back exactly where you were, output and all.

One script sets up both, for the one human who owns the box.

## The big decision: lean, not fancy

The desktop version of this setup (steves-debian-setup) uses **oh-my-zsh**,
**starship**, **atuin**, and a **tmux plugin manager** that downloads five
plugins from GitHub. That's great on a beefy laptop. On a 2 GB single-board
computer it's the wrong call, for three reasons:

1. **Startup cost.** oh-my-zsh runs a pile of code every time you open a shell.
   On slow SD-card storage you feel it.
2. **Network fetches.** Those plugins are cloned from the internet on first run.
   A provisioning script that needs GitHub to be reachable is a script that
   breaks when GitHub is down — or when the box has no internet yet.
3. **Dependencies.** Every extra tool is another thing to update and another
   thing that can break.

So this script uses **only** what Debian ships in apt, and **zero** plugins that
have to be downloaded. Everything is either built into zsh/tmux or a package
`apt` already knows about. First shell start is instant and nothing phones home.

## The zsh choices, one at a time

**No framework.** Instead of oh-my-zsh, the config is ~25 lines of plain zsh.
Does 90% of what people actually want from oh-my-zsh, at none of the cost.

**Two apt plugins.** Debian packages `zsh-syntax-highlighting` (commands turn
green when valid, red when not) and `zsh-autosuggestions` (ghostly grey
suggestion from your history — press → to accept). These are the two features
worth having. They install like any other package.

**Order matters for one of them.** Syntax-highlighting has to be the *last*
thing loaded, because it wraps the line editor and needs to see everything set
up before it. Load it too early and it silently does nothing. That's why it's
the final line of the file, with a comment saying so.

**`compinit -C`.** Completion normally does a security scan of its files every
day, which costs a beat at startup. On a single-user box that scan buys you
almost nothing, so `-C` skips it. Small speed win that matters on weak hardware.

**A git-aware prompt with no extra program.** The desktop uses `starship`, a
separate binary you have to install and keep updated. This prompt shows the same
key thing — your current git branch — using `vcs_info`, which is *built into
zsh*. One less dependency, same payoff. It looks like:

```
steve@sbc:~/steves-sbc-setup (main)%
```

**Emacs keybindings (`bindkey -e`).** Not about the Emacs editor — it's the set
of keyboard shortcuts (Ctrl-A to jump to line start, and so on) that every SSH
client assumes by default. Setting it explicitly avoids surprises.

## The tmux choices, one at a time

**Zero plugins.** The single feature that actually matters on a server —
sessions surviving a dropped connection — is *built into tmux*. It needs no
plugin at all. So there's no plugin manager here, nothing to download, nothing
to break.

**Prefix is Ctrl-A, not Ctrl-B.** tmux listens for a "prefix" key before its
commands. The default, Ctrl-B, is an awkward reach. Ctrl-A sits under your left
hand. (If you also use GNU `screen`, this will feel familiar — it's screen's
key.)

**`screen-256color`, not `tmux-256color`.** This tells programs what your
terminal can do. The "better" value, `tmux-256color`, needs an extra package
(`ncurses-term`) that a minimal SBC image often doesn't have — and without it,
colours break. `screen-256color` is present *everywhere* out of the box. We
trade a tiny bit of polish (italic text) for "it just works on any image."

**`escape-time 10`.** Without this, tmux waits after you press Esc to see if
it's part of a longer key sequence. In vim over a slow link, that wait makes Esc
feel broken. Ten milliseconds fixes it without causing false triggers.

**Mouse on, big scrollback, intuitive splits.** Quality-of-life: you can click
between panes and scroll with the wheel; 50,000 lines of history are kept; and
`|` / `-` split the window vertically / horizontally, opening the new pane in
the *same folder* you were already in.

## The login-shell switch

Installing zsh doesn't make it *your* shell — you'd still land in the old one
every login. The script runs `chsh` to change your default shell to zsh. It does
this idempotently (checks first, skips if already done) and reversibly (you can
`chsh` back any time). Don't want it touched at all? Run with `SHELL_NO_CHSH=1`.

The change takes effect on your next login, not immediately — so after the first
run, log out and back in to land in zsh.

## Who it configures

Like the podman stage, this targets the box's *human owner*, not root — figured
out from `$SUDO_USER` (the account that ran `sudo`), or `$TARGET_USER` if you're
running as root directly. The dotfiles are written into that user's home and
owned by that user, not root, so zsh will actually read them.

## How it was checked

- `shellcheck -x` clean, like every script here.
- The generated `.zshrc` was fed to `zsh -n` (syntax check) — parses clean.
- The generated `.tmux.conf` was loaded by a real `tmux` — parses clean.

As with the rest of the repo, that verification ran on an amd64 box, not on the
Pinebook itself.
