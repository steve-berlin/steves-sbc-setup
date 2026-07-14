# `setup/remove-xfce.sh` explained

Plain-language walkthrough of XFCE uninstaller. Want to use it? README enough — this the "why built this way" version.

## What it's for

Many SBC images ship full XFCE desktop. Box that live in cupboard and only talk SSH never draw pixel — desktop just sit there eating RAM (few hundred MB), disk, and update time. This script take it off.

```sh
./setup/remove-xfce.sh --dry-run   # see exactly what would go
sudo ./setup/remove-xfce.sh        # asks before deleting
```

## The one destructive script here

Everything else in repo safe to re-run, backs up what it replaces, undo-able. This one **purge** packages — remove them *and* their config. No undo button. Re-installing XFCE later gives fresh desktop, not old one back.

Because of that, two rules the other scripts don't have:

1. **Not in bootstrap.** Never runs automatically. You call it, on purpose.
2. **It asks.** Prints list, waits for `y`. Skip prompt with `XFCE_YES=1` — but then you asked for it.

## The "don't saw off your own branch" guard

Run this from XFCE terminal, script would delete desktop while you typing in it. So: if graphical session active (`$DISPLAY` set), it refuse. Run from TTY or over SSH instead.

Dry run allowed from desktop — it changes nothing.

Also refuses when nobody at keyboard (cron, script) unless `XFCE_YES=1`. No unattended desktop deletion.

## How it picks packages

Not one fixed list — package names differ between Debian, Ubuntu, Armbian images. Instead **patterns**: `xfce4*`, `thunar*`, `lightdm*`, `xfwm4*`, and friends. Script ask dpkg what installed, keep names matching pattern, purge those.

Only *top-level* desktop things listed. Pile of `libxfce4…` libraries underneath left to `apt-get autoremove --purge`, which sweep them once nothing need them. Listing libraries by hand = way to accidentally rip out something shared.

`XFCE_PURGE_X=1` go further: also drop X server itself (`xserver-xorg*`, `xinit`). Leave unset if anything still want X — VNC/RDP server, or headless X11 app under Xvfb.

## Boot target

Desktop login (`lightdm`) gone. Boot target still say "start graphical login." Leave it, boot hang waiting for desktop that no longer exist. So script flip default to `multi-user.target` — plain console. Reboot, you land at text login, like server should.

## What it leaves alone

Your home folder. `~/.config/xfce4`, `~/.cache/sessions` etc stay. Script tells you they there; deleting your own files is your call, not root's.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` on dev box listed matching packages, took no action.
- Guards tested: graphical session refused (real run), allowed (dry run).
