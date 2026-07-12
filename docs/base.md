# `setup/base.sh` explained

Plain-language walkthrough of base provisioning stage. Want use it? README enough — this "why built this way" version.

## What it's for

Turn utilities on. Fresh install = empty apartment: get electricity, water, heat working first. Script do four boring-but-essential things every other stage assume already done.

## The four things

**Basic packages.** `curl`, `ca-certificates`, `gnupg`, friends — tools later stages need to fetch and verify things. Groundwork.

**`chrony`, for the clock.** Surprising one. Laptop have tiny watch battery, keep time while unplugged. Most single-board computers *don't*. Pinebook boot, genuinely believe it January 1st, 1970.

Why matter? Every secure website (`https://`) hand over certificate saying "valid until such-and-such date." Computer check that against *today*. Against 1970, every certificate on Earth look like far future, so every download fail with baffling error. `chrony` ask internet what time actually is, fix clock. Must run *before* anything download over HTTPS — why it live in first stage.

**`zram` — compressed memory.** Pinebook have only 2 GB RAM. Memory fill up, normal computer shove overflow onto disk ("swap") — slow, and on SD card, wear card out. `zram` cleverer: take chunk of memory, *compress* whatever you put in it — roughly three pages squeezed into space of one. Give up half RAM, get more than that back. Vacuum-seal winter clothes to fit more in same suitcase. Never touch disk = no card wear.

Config set `ALGO=zstd` (fast, good compressor) and `PERCENT=50` (use half of RAM). Choice ripple into `harden.sh` later — see note there about `vm.swappiness`.

**Automatic security updates.** `unattended-upgrades`, configured to install *security* patches on own. Deliberately narrow: won't pull big new kernel that might reboot into something broken while you not watching. Just security fixes.

## Why it's idempotent (and how)

Run twice, second run do nothing. Packages already installed skipped. Config files compared byte-for-byte, only rewritten if actually changed — and if something *is* rewritten, old version saved as `<file>.bak.<timestamp>` first. Re-run always safe.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` print every package install and file write without touching anything.

Like rest of repo, that ran on amd64 box. zram sizing and chrony behaviour exactly where first *real* Pinebook run earn its keep.