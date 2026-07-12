# `setup/tailscale.sh` explained

Plain-language walkthrough of Tailscale stage. Want to use it? README enough — this the "why built this way" version.

## What it's for

Secret tunnel to your box. Tailscale build private encrypted network between *your own* devices — laptop, phone, this SBC — so they reach each other like plugged into same wall, from anywhere on Earth. No opening router ports, no exposing anything to public internet.

Important: this **not** VPN kind that hide browsing (NordVPN and like). Those route traffic *out* through someone else's servers for privacy. Tailscale opposite job — let *you* get *in* to your own machines. Different tool, different purpose.

## The two fiddly bits it handles

**Figuring out which package to install.** Tailscale only publish packages for `debian` and `ubuntu`. But Armbian, Raspberry Pi OS, Mint are those systems *wearing costume* — Debian or Ubuntu underneath, different name on label. So script read `/etc/os-release`, look at `ID` then `ID_LIKE` fields, work out real base. Override guess with `TS_DISTRO` and `TS_CODENAME` if wrong.

**Failing loudly instead of quietly.** Before writing repo config, script test-fetch Tailscale signing key for your specific version. If Tailscale not publish for your version, stop *right there* with clear message. Alternative — writing broken repo — make `apt update` spit 404 errors every future run. Miserable to debug later.

## What it deliberately does NOT do

**It doesn't log you in.** Joining Tailscale network normally need browser. Headless box got none. So script install everything, start service, then tell you run `sudo tailscale up` yourself and follow link. Want automation? Hand script `TS_AUTHKEY` (pre-made login token) and it join on own. Either way, install and login stay separate on purpose.

## Why the stage order matters

Runs *after* `harden.sh`. Deliberate: `harden.sh` already installed firewall rule trusting `tailscale0` interface. So moment Tailscale bring interface up, already welcome — everything else stay locked. Set guest list before guest arrive.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` show repo setup and install steps without touching system.

Live repo fetch and join only exercisable on networked box actually being provisioned — dry-run stop short of writing anything.