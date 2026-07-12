# `setup/backup.sh` explained

Plain-language walkthrough of backup stage. Want to use it? README enough — this "why built this way" version.

## What it's for

Copy important files, automatic, so dead SD card no mean everything lost. Use `restic`, modern backup tool, on daily timer.

Two things make restic good:

- **Encrypted.** Whoever hold your backup drive (cloud bucket, NAS, USB stick) can't read files without key. Safe to store anywhere.
- **Deduplicated.** Back up same file hundred days running, stored *once*, not hundred times. Backups stay small.

Default: backs up `/etc` (system config) and `/home` (your stuff), skips caches and junk, keeps rolling window: 7 daily, 4 weekly, 6 monthly snapshots, prunes older ones automatic. Job runs low priority — never bog down one-core SBC.

## The two things you MUST understand

**1. The encryption key is your only key.** On first run, script generates random key at `/etc/restic/password` and prints big, loud warning. That key is the *only* thing on Earth that can decrypt your backups. No reset, no "forgot password," no support line. If the SD card dies and you never copied that key somewhere else, every backup you own becomes permanently unreadable noise.

So: the day you run this, copy the key off the machine into a password manager:

```
sudo cat /etc/restic/password
```

**2. The timer stays OFF until you set a destination.** A backup job pointed at nowhere is *worse* than no backup job — it sits there looking green and healthy while protecting nothing, and you find out only when you need it. So the script refuses to enable the daily timer until you have told it *where* to back up. Edit `/etc/restic/env`, set `RESTIC_REPOSITORY` (NAS path, S3 bucket, USB drive — restic supports many), then re-run the script and the timer turns on.

## A couple of careful details

**It reads your config by searching it, not running it.** To check destination set, script `grep`s env file instead of *executing* it. Config files get hand-edited, and "running" file mean executing whatever typo accidentally turned into command. Searching safe; sourcing not.

**The backup service protects the system while it runs.** systemd unit use `ProtectSystem=full` (most of filesystem read-only to backup job) — deliberately *not* `strict`, because `strict` block writing to repo living on `/mnt` or `/srv`, common place to put one.

**`restic init` only needs to work once.** First backup must create repo; every run after, "create" correctly fails because repo already exist. Unit marks that step with `-` prefix so expected failure ignored, not abort whole backup.

## How it was checked

- `shellcheck -x` clean.
- Both generated systemd units (`.service` and `.timer`) passed `systemd-analyze verify`.
- `--dry-run` shows config and unit creation without writing secrets or enabling anything.

Ran on amd64. First real backup — create repo, push first snapshot — happen on box itself once destination set.