# `setup/harden.sh` explained

Plain-language walkthrough of the hardening stage. If you just want to use it,
the README is enough — this is the "why is it built this way" version.

## What it's for

Putting locks on the doors. A computer that sits on a network all day, with
nobody watching it, is a target. This script closes it down to the minimum: only
the ways in that you actually use, only the settings that are safe. Three layers.

## Layer 1 — SSH

SSH is how you type commands into a computer that's somewhere else. Two changes:

- **Root can't log in directly.** You log in as yourself, then step up when you
  need to. An attacker guessing passwords now has to guess *two* things.
- **Passwords are turned off in favour of keys.** A key is essentially an
  unguessable, 600-character password your computer holds for you. Nobody
  brute-forces that.

**The booby trap, and the guard for it.** If you turn off password login on a
headless box *before* your key is installed, you've just permanently locked
yourself out of a computer with no keyboard. So the script checks for a working
key first (`has_ssh_key`). No key found? It leaves password login on and warns
you loudly. It *cannot* lock you out. Add your key, re-run, and the lockdown
finishes. (`FORCE_SSH_KEYONLY=1` overrides, if you know what you're doing.)

**It validates before it reloads.** `sshd -t` checks the new config for typos
*before* restarting SSH. Restarting SSH with a broken config on a remote machine
is the *other* way to lose access forever. And drop-in configs like ours are
silently ignored unless the main config has an `Include` line — so the script
hard-fails if that line is missing, rather than writing a file that does nothing.

## Layer 2 — sysctl (kernel knobs)

`sysctl` settings are little dials in the kernel. Some for speed, some for safety.

**BBR — free network speed.** The classic way computers decide how fast to send
data treats *any* lost packet as "the network is congested, slow down!" On wifi,
packets get lost for random reasons that have nothing to do with congestion, so
the old way needlessly crawls. BBR actually *measures* the connection instead of
guessing. Real speed, for free. **But** it's a kernel module that isn't built
into every board, so the script checks whether the kernel offers BBR and only
turns it on if so — enabling a dial the kernel doesn't have makes the whole
config fail to load. When BBR *is* present, it also writes a `modules-load.d`
file so it survives a reboot.

**`vm.swappiness = 100` — the backwards-looking one.** Normally you set this
*low* (like 10) meaning "avoid swapping, it's slow." We set it to the *maximum*.
Why? Because of `base.sh`: we're not swapping to a slow disk, we're swapping into
fast, compressed RAM (`zram`). Swapping there is cheap and *better* than throwing
away useful cached data. Same dial as everyone else, opposite setting, because
the hardware underneath changed.

**`rp_filter = 2`, not 1.** This is a spoofing guard. Strict mode (1) drops any
packet that arrives by a "weird" route. But Tailscale legitimately creates weird,
asymmetric routes (subnet routers, exit nodes), and strict mode would break them.
Loose mode (2) keeps the protection without the breakage — Tailscale's own
documented recommendation.

The rest are standard hardening: ignore redirects, drop source-routed packets,
hide kernel pointers, protect symlinks. Boring and correct.

## Layer 3 — the firewall (nftables)

**Default-deny.** Every incoming connection is refused unless it's on the guest
list. The guest list:

- loopback (the machine talking to itself)
- replies to conversations *you* started
- ICMP (ping, and path-MTU discovery, which real traffic needs)
- DHCP replies (so the box can get an IP address)
- SSH on port 22
- **anything at all arriving over `tailscale0`** — Tailscale traffic is already
  encrypted and authenticated, so it's trusted

**It validates before it loads.** `nft -c` parses the ruleset first. A ruleset
that fails to load leaves the box with *no* firewall — worse than a wrong one. A
ruleset that loads *wrong* could lock out SSH. So: check, then apply.

Note: rootless Podman (the next-but-one stage) doesn't need any firewall
`forward` rules, because it networks through pasta/slirp4netns rather than a
bridge. Rootful Docker *would*. Another quiet win for the rootless choice.

## How it was checked

- `shellcheck -x` clean.
- The generated ruleset was fed to `nft -c -f` — parses valid.
- All 17 sysctl keys were confirmed to exist on kernel 6.12, and BBR
  availability was confirmed on the test box.
- `--dry-run` shows every change without applying it.

Ran on amd64. On an older SBC kernel a sysctl key could be missing; if so,
`sysctl --system` errors on it and you gate that key the same way BBR is gated.
