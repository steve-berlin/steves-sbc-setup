# `setup/bootstrap.sh` explained

Plain-language walkthrough of unattended runner. Want to use it? README enough — this the "why built this way" version.

## What it's for

Seven provisioning stages, one command, no questions:

```sh
./setup/bootstrap.sh --dry-run   # rehearse: print everything, change nothing
./setup/bootstrap.sh             # do it
```

That whole job. It own no logic of its own — it call other scripts, in right order, and pass `--dry-run` down if you gave it.

Want questions instead? That `wizard.sh`. Same stages underneath. Bootstrap = machine path (fresh SD card, second identical box, cron). Wizard = human path.

## The order is the point

```
base → harden → tailscale → podman → shell → monitor → backup
```

Not alphabetical, not random. Two links load-bearing:

- **harden before tailscale.** harden install firewall that block everything inbound *except* things arriving on `tailscale0`. Rule must exist before Tailscale bring interface up — otherwise short window where box on internet with no firewall, and (worse) reboot into wrong order leave you unsure which state you in.
- **harden before monitor.** monitor open metrics port on *every* interface (`0.0.0.0:9100`). Only thing keeping that private = firewall from harden. Reverse order = box briefly publishing its stats to whole world.

`base` first because everything else need its packages and its clock. SBC have no battery-backed clock: boot with clock at 1970, every HTTPS download fail ("certificate not valid yet"), and half remaining stages break in confusing way. chrony fix clock. So chrony go first.

## Skipping stages

```sh
SKIP="tailscale monitor" ./setup/bootstrap.sh
```

`skipped()` walk words in `SKIP`, match stage name. Not fancy. Enough.

Careful: skip `harden` and keep `monitor`, you *did* just publish `:9100` to world. Script warn about missing firewall (monitor.sh check), but it not stop you. Repo assume you adult.

## Stages independent on purpose

Every stage script installs own packages, checks own preconditions, safe to run alone:

```sh
sudo ./setup/harden.sh          # just the firewall + sshd + sysctl
sudo ./setup/backup.sh          # just restic
```

No stage assume earlier stage ran. Cost: little repetition (each one call `apt_install`). Payoff: you can re-run *one* thing after changing *one* thing, instead of whole box. On slow board that difference between 20 seconds and 10 minutes.

## Dry run go all the way down

```bash
	local stage args=()
	if [ "$DRY_RUN" = 1 ]; then
		args+=(--dry-run)
	fi
	…
	"$SELF_DIR/$stage.sh" ${args[@]+"${args[@]}"}
```

`--dry-run` on bootstrap = `--dry-run` on every child. So rehearsal really rehearse whole thing, not just outer script. Weird-looking `${args[@]+"${args[@]}"}` = "expand this list if it has anything in it, otherwise expand to nothing" — safe way to pass array that might be empty when `set -u` is on and would otherwise call empty array "unset variable."

## What it refuses to do for you

At end, real run print list:

```
  1. sudo tailscale up                  (if TS_AUTHKEY was not supplied)
  2. sudo cat /etc/restic/password      (store this off-box, or backups are lost)
  3. edit /etc/restic/env, then re-run setup/backup.sh to enable the timer
  4. add a key to ~/.ssh/authorized_keys, re-run setup/harden.sh to kill password auth
```

Four things automation deliberately stop short of. Each need human: browser login, decision where backups live, key you generate, secret you store somewhere safe. Script that guessed at these would either fail silently or lock you out of own box. Better: take you to door, hand you key, say "you open it."

(Wizard ask you those questions up front and fill them in — that its entire reason to exist.)

## How it was checked

- `shellcheck -x` clean.
- `./setup/bootstrap.sh --dry-run` reach "bootstrap complete" — that repo's smoke test, run after every change.
