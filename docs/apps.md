# `setup/apps.sh` explained

Plain-language walkthrough of optional-apps stage. Want to use it? README enough — this the "why built this way" version.

## What it's for

Other stages build *box*. This one put something useful **on** it.

Two apps today:

- **dfs** ([steves-domainless-filehosting](https://github.com/steve-berlin/steves-domainless-filehosting)) — your own small Google Drive. Accounts, web page you drag files into, share links, REST API. Files encrypted on disk, so thief who steal SD card get scrambled junk, not your files.
- **navidrome** — your own small Spotify. Web player in browser, and Subsonic API so any Subsonic phone app stream your music from box.

Run it:

```sh
sudo ./setup/apps.sh                    # APPS="dfs navidrome" by default
APPS="navidrome" ./setup/apps.sh --dry-run   # pick one
```

## Why not in bootstrap

Bootstrap = things every box want. App = thing *you* want. Also: building it need internet and few minutes of CPU. Stays opt-in.

## Why build from source

dfs pure Go, standard library only, no dependencies. Result single static binary — copy it anywhere, it run. No apt package exist, so script clone repo, compile, drop binary in `/usr/local/bin/dfs`.

Four build details load-bearing:

- **Go must be new enough, and often isn't.** dfs's `go.mod` ask for newer Go than Debian ship. Go **1.21 and up** solve that themselves: `GOTOOLCHAIN=auto` make them download exact toolchain `go.mod` name. Older Go can't — bookworm ship **1.19**, which have no `GOTOOLCHAIN` at all, and just refuse. So script check version first (`go_usable`), try apt, and if that still too old, install upstream Go tarball into `/usr/local/go` — downloaded, sha256 checked against Go's own release index, unpacked.
- **No `go -C`.** Shorter way to say "build in that folder" is `go -C dir build` — but that flag arrive in Go 1.20, and older Go answer `flag provided but not defined: -C`. Script `cd` in subshell instead. Works on every Go.
- **`-p 2`.** Go compile one file per CPU core by default. Four compilers on 2 GB board = out of memory. Cap at two.
- **Commit stamp.** After build, script save commit hash it built. Re-run: hash same and binary there = skip build. Compiling on Pinebook is minutes; skipping matter.

## How it runs

Own system user `dfs`, no login shell. Data in `/var/lib/dfs`, mode `0700` — that folder hold master key plus everyone's encrypted files, nobody else on box read it.

systemd unit sandboxed hard: whole filesystem read-only except its own data dir, `/home` invisible, TCP/IP sockets only, 512 MB memory ceiling. If someone break in through web UI, they land in small box.

## The `DFS_PUBLIC` gate

`/etc/dfs/env`, written once, never overwritten (it your intent, not ours):

```
DFS_ADDR=:8443
DFS_PUBLIC=
DFS_OPTS=
```

`DFS_PUBLIC` = `host:port` users type in browser. Also name baked into self-signed TLS cert. Empty = cert for nobody, service at no address. So while it empty, **service stay disabled on purpose**. Set it, re-run script, service come up.

Same rule as restic timer: thing that look green while doing nothing worse than thing honestly off.

Tailscale IP work fine here — that whole point of "domainless."

## Firewall

harden.sh ruleset open **no** app port — not 8443 (dfs), not 4533 (navidrome). Both reachable over `tailscale0` only. Deliberate: file host or music server on open internet should be decision, not accident. Want it public? Open port yourself in `/etc/nftables.conf`.

Script warn if no ruleset loaded at all — then apps exposed on every interface.

## Navidrome: why .deb, not source

dfs get built from source. Navidrome does **not** — upstream publish `.deb` for arm64/amd64, and building it yourself would drag in Node.js to compile web player. On 2 GB board that painful and pointless. So: download `.deb`, install with apt (apt pull its dependency, `ffmpeg`).

**Checksum checked.** Script also download `navidrome_checksums.txt` from same release and run `sha256sum -c`. Mismatch = `die`, no install. Binary you fetched off internet and run as service should be one upstream actually signed off on.

**Version.** `latest` by default — script ask GitHub API for newest tag once, then use that same tag for everything. Pin it with `NAVIDROME_VERSION=v0.63.2`. Re-run: if version already installed, skip download entirely.

## Navidrome: config and music

Config `/etc/navidrome/navidrome.toml`:

```toml
MusicFolder = "/srv/music"
DataFolder = "/var/lib/navidrome"
Port = 4533
ScanSchedule = "@every 24h"
TranscodingCacheSize = "50MB"
ImageCacheSize = "100MB"
```

Caches deliberately small — they live on SD card, and SD cards die from writing. Scan once a day (Navidrome also notice new files as they appear).

Music folder `/srv/music`, owned by **you**, not by service. Navidrome only ever read it. Change path with `NAVIDROME_MUSIC=/games/music` or whatever.

**First visitor become admin.** Navidrome have no admin password until someone open web page and make one. So: after enabling, go to `http://<box>:4533/` and claim it *before* anyone else can. Firewall keep it on tailnet, so "anyone else" is small crowd — but claim it anyway.

## Making accounts

Script make no users. You do:

```sh
sudo -u dfs DFS_PASSWORD='a-strong-passphrase' dfs useradd alice --data /var/lib/dfs
```

Then browse `https://<DFS_PUBLIC>/`, sign in, drag file in. Browser warn about self-signed cert — expected. Compare fingerprint dfs print at startup.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` prints every action, touches nothing.
- Generated `dfs.service` fed to `systemd-analyze verify` — only complaint was missing binary (not built on dev box), no config errors.
- Generated `navidrome.toml` parsed by real TOML parser — valid.
- Checksum path exercised for real: downloaded `navidrome_0.63.2_linux_amd64.deb` + `navidrome_checksums.txt`, `sha256sum -c` said `OK`.
