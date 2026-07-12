# `setup/tailscale.sh` explained

Plain-language walkthrough of the Tailscale stage. If you just want to use it,
the README is enough — this is the "why is it built this way" version.

## What it's for

A secret tunnel to your box. Tailscale builds a private, encrypted network
between *your own* devices — laptop, phone, this SBC — so they can reach each
other as if they were all plugged into the same wall, from anywhere on Earth. No
opening ports on your router, no exposing anything to the public internet.

Important: this is **not** the kind of VPN that hides your browsing (NordVPN and
the like). Those route your traffic *out* through someone else's servers for
privacy. Tailscale is the opposite job — letting *you* get *in* to your own
machines. Different tool, different purpose.

## The two fiddly bits it handles

**Figuring out which package to install.** Tailscale only publishes packages for
`debian` and `ubuntu`. But Armbian, Raspberry Pi OS, and Mint are those systems
*wearing a costume* — Debian or Ubuntu underneath with a different name on the
label. So the script reads `/etc/os-release`, looks at the `ID` and then the
`ID_LIKE` fields, and works out which base your system really is. You can
override its guess with `TS_DISTRO` and `TS_CODENAME` if it gets it wrong.

**Failing loudly instead of quietly.** Before writing the repository config, the
script does a test fetch of Tailscale's signing key for your specific version. If
Tailscale doesn't publish for your version, it stops *right there* with a clear
message. The alternative — writing a broken repo — would make `apt update` spit
404 errors on every future run, which is a miserable thing to debug later.

## What it deliberately does NOT do

**It doesn't log you in.** Joining a Tailscale network normally needs a browser,
which a headless box doesn't have. So the script installs everything, starts the
service, and then tells you to run `sudo tailscale up` yourself and follow the
link. If you'd rather automate it, hand the script a `TS_AUTHKEY` (a pre-made
login token) and it joins on its own. Either way, installation and login are kept
separate on purpose.

## Why the stage order matters

This runs *after* `harden.sh`. That's deliberate: `harden.sh` already installed
the firewall rule that trusts the `tailscale0` interface. So the moment Tailscale
brings that interface up, it's already welcome — and everything else stays
locked. Set the guest list before the guest arrives.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` shows the repo setup and install steps without touching the
  system.

The live repo fetch and join can only really be exercised on a networked box
that's actually being provisioned — the dry-run stops short of writing anything.
