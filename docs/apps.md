# `setup/apps.sh` explained

Plain-language walkthrough of optional-apps stage. Want to use it? README enough — this the "why built this way" version.

## What it's for

Other stages build *box*. This one put something useful **on** it.

Today one app: **dfs** ([steves-domainless-filehosting](https://github.com/steve-berlin/steves-domainless-filehosting)) — your own small Google Drive. Accounts, web page you drag files into, share links, REST API. Files encrypted on disk, so thief who steal SD card get scrambled junk, not your files.

Run it:

```sh
sudo ./setup/apps.sh              # APPS=dfs by default
APPS="dfs" ./setup/apps.sh --dry-run
```

## Why not in bootstrap

Bootstrap = things every box want. App = thing *you* want. Also: building it need internet and few minutes of CPU. Stays opt-in.

## Why build from source

dfs pure Go, standard library only, no dependencies. Result single static binary — copy it anywhere, it run. No apt package exist, so script clone repo, compile, drop binary in `/usr/local/bin/dfs`.

Three build details load-bearing:

- **`GOTOOLCHAIN=auto`.** dfs's `go.mod` want newer Go than Debian ship. `auto` = Go fetch exact toolchain it need. Without it: hard error, refuse to build.
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

harden.sh ruleset **not** open port 8443. So dfs reachable over `tailscale0` only. Deliberate: file host on open internet should be decision, not accident. Want it public? Open port yourself in `/etc/nftables.conf`.

Script warn if no ruleset loaded at all — then dfs would be exposed everywhere.

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
