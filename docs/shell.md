# `setup/shell.sh` explained

Plain-language walkthrough of zsh + tmux stage. Want to use it? README enough — this the "why built this way" version.

## What it's for

Two comforts for computer you only talk to over SSH:

- **zsh** — nicer shell than default. Tab-completion show menu, suggestions from history as you type, colours flag typo before Enter.
- **tmux** — "screen saver for work." Start long job in tmux, wifi drop, SSH die — job keep running. Reconnect, run `tmux attach`, back exactly where you were, output and all.

One script set up both, for one human who own box.

## The big decision: lean, not fancy

Desktop version (steves-debian-setup) use **oh-my-zsh**, **starship**, **atuin**, and **tmux plugin manager** that download five plugins from GitHub. Great on beefy laptop. On 2 GB single-board computer, wrong call, three reasons:

1. **Startup cost.** oh-my-zsh run pile of code every shell open. On slow SD-card storage you feel it.
2. **Network fetches.** Those plugins cloned from internet on first run. Provisioning script that need GitHub reachable = script that break when GitHub down — or when box have no internet yet.
3. **Dependencies.** Every extra tool = another thing to update, another thing that break.

So script use **only** what Debian ship in apt, and **zero** plugins that need download. Everything built into zsh/tmux or package `apt` already know. First shell start instant. Nothing phone home.

Want fancy tools? Available as **opt-in** — see "Rich mode" at end. Point: *default* stay lean and offline. You choose to add weight, not have it forced.

## The zsh choices, one at a time

**No framework.** Instead of oh-my-zsh, config ~25 lines plain zsh. Do 90% of what people actually want from oh-my-zsh, none of cost.

**Two apt plugins.** Debian packages `zsh-syntax-highlighting` (commands green when valid, red when not) and `zsh-autosuggestions` (grey ghost suggestion from history — press → to accept). Two features worth having. Install like any other package.

**Order matters for one of them.** Syntax-highlighting must be *last* thing loaded — it wrap line editor, need to see everything set up first. Load too early, it silently do nothing. That why it final line of file, with comment saying so.

**`compinit -C`.** Completion normally do security scan of its files every day, cost beat at startup. On single-user box that scan buy almost nothing, so `-C` skip it. Small speed win, matter on weak hardware.

**Git-aware prompt, no extra program.** Desktop use `starship`, separate binary to install and keep updated. This prompt show same key thing — current git branch — using `vcs_info`, *built into zsh*. One less dependency, same payoff. Look like:

```
steve@sbc:~/steves-sbc-setup (main)%
```

**Emacs keybindings (`bindkey -e`).** Not about Emacs editor — set of keyboard shortcuts (Ctrl-A jump to line start, etc.) every SSH client assume by default. Set explicitly, avoid surprises.

## The tmux choices, one at a time

**Zero plugins.** Single feature that actually matter on server — sessions surviving dropped connection — *built into tmux*. Need no plugin. So no plugin manager here, nothing to download, nothing to break.

**Prefix is Ctrl-A, not Ctrl-B.** tmux listen for "prefix" key before its commands. Default Ctrl-B = awkward reach. Ctrl-A sit under left hand. (Also use GNU `screen`? Feel familiar — it screen's key.)

**`screen-256color`, not `tmux-256color`.** Tell programs what terminal can do. "Better" value `tmux-256color` need extra package (`ncurses-term`) that minimal SBC image often lack — without it, colours break. `screen-256color` present *everywhere* out of box. Trade tiny polish (italic text) for "just work on any image."

**`escape-time 10`.** Without this, tmux wait after Esc press to see if part of longer key sequence. In vim over slow link, that wait make Esc feel broken. Ten milliseconds fix it without false triggers.

**Mouse on, big scrollback, intuitive splits.** Quality-of-life: click between panes, scroll with wheel; 50,000 lines of history kept; `|` / `-` split window vertically / horizontally, new pane open in *same folder* you were in.

## The login-shell switch

Installing zsh not make it *your* shell — you still land in old one every login. Script run `chsh` to change default shell to zsh. Idempotent (check first, skip if done) and reversible (`chsh` back any time). Don't want it touched? Run with `SHELL_NO_CHSH=1`.

Change take effect on next login, not immediately — so after first run, log out and back in to land in zsh.

## Who it configures

Like podman stage, target box's *human owner*, not root — figured from `$SUDO_USER` (account that ran `sudo`), or `$TARGET_USER` if running as root directly. Dotfiles written into that user's home, owned by that user, not root, so zsh actually read them.

## Rich mode (`SHELL_RICH=1`)

Run `SHELL_RICH=1 ./setup/shell.sh` (or set before `bootstrap.sh`) and script add two popular extras on top of lean base:

- **starship** — fancy fast prompt: git status, language versions, exit codes, more. *Replace* built-in git prompt.
- **atuin** — supercharged shell history: full-text search of every command ever run, synced and stored in database, bound to Ctrl-R.

Three things to understand before flipping it on:

**Not apt packages.** Neither in Debian, so script install them by downloading each project's official installer from internet and running it — starship into `/usr/local/bin` (system-wide), atuin into user's own `~/.atuin`. Means rich mode **need internet** at setup time and ask you to trust those upstream installers. Lean default never do either. That whole reason it opt-in, not default.

**Extra `~/.zshrc` lines guarded.** They read `command -v starship >/dev/null && eval "$(starship init zsh)"` — meaning "only turn starship on if actually installed." So if install ever fail or you remove binary, shell still start fine, quietly fall back to native prompt. Nothing break.

**starship win prompt.** Lean config already set git-aware prompt; starship load after and take over completely. Intended — you ask for starship, you get starship. Native prompt just fallback.

Everything else (zsh plugins, tmux, aliases, shell switch) identical to lean mode. Rich mode only *add*.

## How it was checked

- `shellcheck -x` clean, like every script here.
- Both lean and rich generated `.zshrc` files fed to `zsh -n` (syntax check) — both parse clean.
- Generated `.tmux.conf` loaded by real `tmux` — parses clean.
- Lean `--dry-run` confirmed to mention neither starship nor atuin; rich `--dry-run` confirmed to install both and append their init lines.

Like rest of repo, that verification ran on amd64 box, not on Pinebook itself.