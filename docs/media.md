# `setup/media.sh` explained

Plain-language walkthrough of USB storage stage. Want to use it? README enough — this the "why built this way" version.

## What it's for

Plug USB stick into laptop with desktop: icon appear, folder open. Nothing magic — file manager watching, and it mount drive for you.

Headless box have no file manager. Plug stick in, kernel see it, `lsblk` show it… and nothing else happen. Files not reachable until you mount them by hand, every time, remembering device name that change between boots.

This script give box that missing piece. Two halves:

1. **Hotplug** — plug stick in, it appear under `/media/<label>`. Like desktop.
2. **Pinned drive** — one drive always mount at same path (`/srv/music`), so service like Navidrome can point at it and not care about plugging order.

```sh
sudo ./setup/media.sh                                    # hotplug only
MEDIA_UUID=1234-ABCD sudo ./setup/media.sh               # + pin one drive
MEDIA_UUID=1234-ABCD MEDIA_MOUNT=/srv/music MEDIA_RO=1 sudo ./setup/media.sh
```

Run with no UUID = print table of what attached right now, so you can copy UUID from it.

## Why not udisks (thing desktops use)

udisks2 mount drives *for a logged-in session*, and ask polkit "is this person sitting at machine allowed?" Headless box have no session and nobody sitting anywhere. udisks would install pile of packages and then do nothing useful.

systemd already have all needed parts. Use those.

## How hotplug work

Three pieces:

**udev rule.** udev = thing kernel tell "new device appeared." Rule match: USB, block device, actually carrying filesystem (`ID_FS_USAGE=="filesystem"` — skip swap partitions, RAID members, LVM chunks). Match = run helper script.

**udev cannot mount.** Important, and non-obvious: udev run its programs in own private mount namespace. Mount inside it = mount that *vanish* when program exit. Every "why doesn't my udev mount rule work" question on internet is this.

**So helper call `systemd-mount`.** That create real, transient mount unit in real namespace. Three flags:

- `--automount=yes` — don't mount now; mount first time someone actually *look* at folder. Spinning drive stay asleep until used.
- `--collect` — clean unit up afterward, no litter.
- No unmount rule needed: unit `BindsTo=` device. Pull stick, systemd notice device gone, tear mount down itself.

**Mountpoint name.** From drive's label (`MUSIC` → `/media/MUSIC`), fall back to UUID. Label come from whoever formatted drive = untrusted text that end up in path, so every character outside `A-Za-z0-9._-` become underscore.

**Options.** `nosuid,nodev` on everything: USB stick should never be able to carry root-setuid binary or device node onto your box. For vfat/exfat/ntfs also `uid=`/`gid=`/`umask=` — those filesystems store *no* owner, so owner decided at mount time. Script bake in box owner's numeric uid, so files readable by you and by services.

## How pinned drive work

`MEDIA_UUID=…` = write line to `/etc/fstab`:

```
UUID=1234-ABCD /srv/music vfat nofail,x-systemd.device-timeout=5,nosuid,nodev,noatime,ro,uid=1000,gid=1000,umask=0022 0 0
```

Pieces that matter:

- **UUID, not `/dev/sda1`.** Device names shuffle. Plug in second stick, yesterday's `sda1` become today's `sdb1`, and box mount wrong thing (or nothing). UUID belong to filesystem, never move.
- **`nofail`** — most important word on line. Without it: boot with drive unplugged, systemd wait for device that never come, boot stall. On headless box, no screen to tell you why. `x-systemd.device-timeout=5` cap wait to 5 seconds.
- **`ro`** (`MEDIA_RO=1`) — Navidrome only read music. Read-only mean scanner bug or yanked cable cannot corrupt library.
- **Idempotent** — UUID already in fstab = leave alone, don't add twice. Script back up `/etc/fstab` before touching, and run `findmnt --verify` after, because broken fstab = box that won't boot.

## Filesystem drivers

Debian not ship exFAT or NTFS drivers by default. Missing driver look exactly like broken stick: device there, mount fail. Script `apt install exfatprogs ntfs-3g dosfstools` so all three common USB formats just work.

## Pull cable safely

Automount mean data may still sit in memory, not yet written. Before yanking:

```sh
sudo systemctl stop media-MUSIC.mount   # or: sudo umount /media/MUSIC
```

Read-only mounts (`MEDIA_RO=1`) have nothing to flush — another reason library drives should be `ro`.

## Hardware warning (Pinebook A64)

USB ports on A64 are weak. Bus-powered spinning 2.5" drive can brown out board middle of scan and take whole box down. Flash stick fine. Real drive = use powered hub.

## How it was checked

- `shellcheck -x` clean; generated helper checked with `dash -n` (udev run it under `/bin/sh`, not bash).
- udev rule fed to `udevadm verify`: `Success: 1, Fail: 0`.
- Fake USB stick made with loop device + `mkfs.vfat`, then dry run confirmed script find its UUID, pick `vfat`, and build correct fstab line with `nofail` and uid mapping.
