# `setup/base.sh` explained

Plain-language walkthrough of the base provisioning stage. If you just want to
use it, the README is enough — this is the "why is it built this way" version.

## What it's for

Turning the utilities on. Think of a fresh install as an empty apartment: before
anything else, you get the electricity, water, and heat working. This script does
the four boring-but-essential things every other stage assumes are already done.

## The four things

**Basic packages.** `curl`, `ca-certificates`, `gnupg`, and friends — the tools
later stages need to fetch and verify things. Nothing exciting, just groundwork.

**`chrony`, for the clock.** Here's the surprising one. Your laptop has a tiny
watch battery that keeps time while it's unplugged. Most single-board computers
*don't*. So when a Pinebook boots, it genuinely believes it's January 1st, 1970.

Why does that matter? Every secure website (`https://`) hands over a certificate
that says "valid until such-and-such date." Your computer checks that against
*today*. Against 1970, every certificate on Earth looks like it's from the far
future, so every single download fails with a baffling error. `chrony` asks the
internet what time it actually is and fixes the clock. It has to run *before*
anything tries to download over HTTPS — which is why it lives in the very first
stage.

**`zram` — compressed memory.** The Pinebook has only 2 GB of RAM. When memory
fills up, a normal computer shoves the overflow onto the disk ("swap"), which is
slow and, on an SD card, wears the card out. `zram` does something cleverer: it
takes a chunk of memory and *compresses* whatever you put in it — roughly three
pages squeezed into the space of one. You give up half your RAM and get more than
that back. It's vacuum-sealing your winter clothes to fit more in the same
suitcase. And because it never touches the disk, there's no card wear.

The config sets `ALGO=zstd` (a fast, good compressor) and `PERCENT=50` (use half
of RAM). This choice ripples into `harden.sh` later — see the note there about
`vm.swappiness`.

**Automatic security updates.** `unattended-upgrades`, configured to install
*security* patches on its own. Deliberately narrow: it won't pull in a big new
kernel that might reboot into something broken while you're not watching. Just
the security fixes.

## Why it's idempotent (and how)

Run it twice and the second run does nothing. Packages already installed are
skipped. Config files are compared byte-for-byte and only rewritten if they
actually changed — and if something *is* rewritten, the old version is saved as
`<file>.bak.<timestamp>` first. So re-running is always safe.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` prints every package install and file write without touching
  anything.

As with the rest of the repo, that ran on an amd64 box. The zram sizing and
chrony behaviour are exactly where the first *real* Pinebook run earns its keep.
