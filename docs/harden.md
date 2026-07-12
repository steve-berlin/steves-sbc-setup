# `setup/harden.sh` explained

Plain-language walkthrough of hardening stage. Want to just use it? README enough. This the "why built this way" version.

## What it's for

Put locks on doors. Computer on network all day, nobody watching = target. Script closes it to minimum: only ways in you use, only settings that safe. Three layers.

## Layer 1 — SSH

SSH = type commands into computer somewhere else. Two changes:

- **Root can't log in directly.** Log in as yourself, step up when need. Attacker guessing passwords now guess *two* things.
- **Passwords off, keys on.** Key = unguessable 600-character password computer holds for you. Nobody brute-forces that.

**The booby trap, and the guard for it.** Turn off password login on headless box *before* key installed = permanently locked out of computer with no keyboard. So script checks for working key first (`has_ssh_key`). No key? Leaves password login on, warns loudly. It *cannot* lock you out. Add key, re-run, lockdown finishes. (`FORCE_SSH_KEYONLY=1` overrides, if you know what you doing.)

**Validates before reload.** `sshd -t` checks new config for typos *before* restarting SSH. Restarting SSH with broken config on remote machine = *other* way to lose access forever. And drop-in configs like ours silently ignored unless main config has `Include` line — so script hard-fails if line missing, rather than writing file that does nothing.

## Layer 2 — sysctl (kernel knobs)

`sysctl` settings = little dials in kernel. Some for speed, some for safety.

**BBR — free network speed.** Classic way computers decide send rate treats *any* lost packet as "network congested, slow down!" On wifi, packets lost for random reasons unrelated to congestion, so old way needlessly crawls. BBR actually *measures* connection instead of guessing. Real speed, free. **But** it kernel module not built into every board, so script checks whether kernel offers BBR and only turns on if so — enabling dial kernel doesn't have makes whole config fail to load. When BBR *is* present, also writes `modules-load.d` file so it survives reboot.

**`vm.swappiness = 100` — the backwards-looking one.** Normally set this *low* (like 10) meaning "avoid swapping, slow." We set *maximum*. Why? Because of `base.sh`: not swapping to slow disk, swapping into fast compressed RAM (`zram`). Swapping there cheap and *better* than throwing away useful cached data. Same dial as everyone else, opposite setting, because hardware underneath changed.

**`rp_filter = 2`, not 1.** Spoofing guard. Strict mode (1) drops any packet arriving by "weird" route. But Tailscale legitimately creates weird asymmetric routes (subnet routers, exit nodes), strict mode would break them. Loose mode (2) keeps protection without breakage — Tailscale's own documented recommendation.

Rest standard hardening: ignore redirects, drop source-routed packets, hide kernel pointers, protect symlinks. Boring and correct.

## Layer 3 — the firewall (nftables)

**Default-deny.** Every incoming connection refused unless on guest list. Guest list:

- loopback (machine talking to itself)
- replies to conversations *you* started
- ICMP (ping, and path-MTU discovery, which real traffic needs)
- DHCP replies (so box can get IP address)
- SSH on port 22
- **anything arriving over `tailscale0`** — Tailscale traffic already encrypted and authenticated, so trusted

**Validates before load.** `nft -c` parses ruleset first. Ruleset that fails to load leaves box with *no* firewall — worse than wrong one. Ruleset that loads *wrong* could lock out SSH. So: check, then apply.

Note: rootless Podman (next-but-one stage) needs no firewall `forward` rules, because it networks through pasta/slirp4netns rather than bridge. Rootful Docker *would*. Another quiet win for rootless choice.

## How it was checked

- `shellcheck -x` clean.
- Generated ruleset fed to `nft -c -f` — parses valid.
- All 17 sysctl keys confirmed to exist on kernel 6.12, BBR availability confirmed on test box.
- `--dry-run` shows every change without applying.

Ran on amd64. On older SBC kernel a sysctl key could be missing; if so, `sysctl --system` errors on it and you gate that key same way BBR gated.