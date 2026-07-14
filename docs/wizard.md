# `setup/wizard.sh` explained

Plain-language walkthrough of interactive front end. Want to use it? README enough — this the "why built this way" version.

## What it's for

Repo have ten scripts and pile of environment knobs. Fine when you know them. Painful when you fresh-flash SD card at 1am and can't remember whether `SHELL_RICH` or `RICH_SHELL`.

Wizard = one command, asks questions, does rest:

```sh
./setup/wizard.sh
```

Four sections: **provision** (which stages), **config** (keys, paths, repository), **apps** (dfs, navidrome), **removal** (XFCE). Then show plan. Then — only then — touch anything.

## Not a replacement for bootstrap

`bootstrap.sh` still the unattended path: no questions, straight through, good for scripts and cron and second identical box. Wizard is human path.

Both call same stage scripts. Neither special. Wizard just fill in env vars you would have typed.

## Nothing happens until you say so

Interview collect answers into variables. Nothing run. Then plan printed:

```
  stages:    base harden shell monitor
  apps:      navidrome
  remove:    (nothing)
  shell:     rich (starship + atuin)
  restic:    (unset — timer stays off)
```

Say no at final prompt = script `die` with "aborted — nothing was changed", and it true: no file written, no package installed. Say yes = it run stages in dependency order, then apps, then removal.

`--dry-run` work too: answer questions, watch every step print what it *would* do.

## Seeding config before stage runs

Trick that make wizard worth having.

`backup.sh` leave timer **disabled** until `RESTIC_REPOSITORY` set. `apps.sh` leave dfs **disabled** until `DFS_PUBLIC` set. Normally: run script, edit `/etc/…/env`, re-run script. Two passes.

Wizard ask for values up front, write env files *before* calling those stages. Stage then find configured box and turn thing on first try.

**Never overwrite.** If env file already exist, wizard keep it and warn your answer was not used. That file might point at live backup repository — clobbering it silently would be way to lose backups. Same rule everywhere in repo: config = operator intent, not ours.

## The one place it deliberately does less

Purging XFCE. Wizard ask "purge XFCE?" — you say yes — and then wizard runs `remove-xfce.sh` **without** `XFCE_YES=1`.

Meaning remover ask *again*, and still refuse if you inside graphical session.

Why annoy you twice? Because one "yes" buried in list of twelve questions should not disarm both safety guards on only irreversible thing in repo. Cheap to press `y` again. Expensive to purge desktop you meant to keep.

## Secrets not echoed

Tailscale auth key read with `read -rs` — nothing appear on screen, nothing land in scrollback of shared terminal. Restic repository and dfs address echo normally: they addresses, not secrets.

## Needs a terminal

`[ -t 0 ]` check: no keyboard = `die`. Wizard that "answer" its own questions from `/dev/null` would take defaults and start installing. Unattended = use `bootstrap.sh` and env vars, on purpose.

## How it was checked

- `shellcheck -x` clean.
- Driven through a real pty (`script -qec`) with scripted answers: minimal path (one stage), full path (backup + both apps + XFCE), and abort path — abort confirmed to change nothing.
- Dry run of full path shows the env-file seeding happening *before* backup and apps stages, exactly as intended.
