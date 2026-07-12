# `setup/backup.sh` explained

Plain-language walkthrough of the backup stage. If you just want to use it, the
README is enough — this is the "why is it built this way" version.

## What it's for

Making copies of your important files, automatically, so a dead SD card doesn't
mean you've lost everything. It uses `restic`, a modern backup tool, on a daily
timer.

Two things make restic good:

- **Encrypted.** Whoever holds your backup drive (a cloud bucket, a NAS, a USB
  stick) can't read your files without the key. Safe to store anywhere.
- **Deduplicated.** If you back up the same file a hundred days running, it's
  stored *once*, not a hundred times. Backups stay small.

By default it backs up `/etc` (your system config) and `/home` (your stuff), skips
caches and junk, and keeps a sensible rolling window: 7 daily, 4 weekly, and 6
monthly snapshots, pruning older ones automatically. The job runs at low priority
so it never bogs down a one-core SBC.

## The two things you MUST understand

**1. The encryption key is your only key.** On first run, the script generates a
random key at `/etc/restic/password` and prints a big, loud warning. That key is
the *only* thing on Earth that can decrypt your backups. There's no reset, no
"forgot password," no support line. If the SD card dies and you never copied that
key somewhere else, every backup you own becomes permanently unreadable noise.

So: the day you run this, copy the key off the machine into a password manager:

```
sudo cat /etc/restic/password
```

**2. The timer stays OFF until you set a destination.** A backup job pointed at
nowhere is *worse* than no backup job — it sits there looking green and healthy
while protecting nothing, and you find out only when you need it. So the script
refuses to enable the daily timer until you've told it *where* to back up. You
edit `/etc/restic/env` and set `RESTIC_REPOSITORY` (a NAS path, an S3 bucket, a
USB drive — restic supports many), then re-run the script and the timer turns on.

## A couple of careful details

**It reads your config by searching it, not running it.** To check whether you've
set a destination, the script `grep`s the env file rather than *executing* it.
Config files get edited by hand, and "running" a file means executing whatever a
typo accidentally turned into a command. Searching is safe; sourcing is not.

**The backup service protects the system while it runs.** The systemd unit uses
`ProtectSystem=full` (most of the filesystem is read-only to the backup job) —
but deliberately *not* `strict`, because `strict` would block writing to a repo
that lives on `/mnt` or `/srv`, which is a common place to put one.

**`restic init` only needs to work once.** The first backup has to create the
repository; every run after that, "create" correctly fails because it already
exists. The unit marks that step with a `-` prefix so that expected failure is
ignored rather than aborting the whole backup.

## How it was checked

- `shellcheck -x` clean.
- Both generated systemd units (`.service` and `.timer`) passed
  `systemd-analyze verify`.
- `--dry-run` shows the config and unit creation without writing secrets or
  enabling anything.

Ran on amd64. The first real backup — creating the repo, pushing the first
snapshot — happens on the box itself once you've set a destination.
