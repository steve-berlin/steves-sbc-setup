# `setup/podman.sh` explained

Plain-language walkthrough of container-host stage. Want to use it? README enough — this "why built this way" version.

## What it's for

Run programs in boxes. **Container** = app packed with everything it need — own libraries, own files — sealed in box so it no fight with rest of machine. Self-hosted web app? Put in container, it can't break system. Podman run those boxes.

## Why Podman, not Docker

Two reasons matter on small always-on box:

**Rootless.** Docker engine run as *root*, all-powerful user — thing escape container, escape as root, own whole machine. Podman run containers as *you*, ordinary user. Escapee is nobody, no power. Safer default.

**Daemonless.** Docker keep background program running 24/7 waiting to manage containers, eat memory even when nothing happen. Podman have no background process — launch containers directly. On 2 GB board, saved memory real.

## The three things that must all be true

Rootless containers great, but fail *baffling* ways if any one of three setup steps missing. Script do all three:

1. **A subuid/subgid range.** For your user to run containers, system must lend block of ~65,000 "pretend" user IDs to hand out inside containers. No block = every `podman run` die with cryptic `newuidmap` error. After adding block, must run `podman system migrate` — Podman already cached old (empty) answer, won't notice otherwise. Script handle both.

2. **Lingering.** Normally, you log out, Linux tear down everything you had running — kill your containers every reboot, since headless box have nobody logged in. `loginctl enable-linger` tell system "let this user's services keep running even with nobody logged in." Without it, nothing survive restart.

3. **Podman 4.4 or newer**, for **Quadlet**. Quadlet = modern magic: write tiny text file describing container, drop in folder, and *systemd* — thing that already start everything else on machine — run it like any other service. Boot-time startup, auto-restart, logs, all free, no extra tools. But need Podman ≥ 4.4. Debian bookworm ship 4.3, so script install Podman anyway and *warn* you rather than pretend. On that version, use older `podman generate systemd` instead.

## Who it configures

Box's *human owner*, not root — whole point is rootless. Figure out who from `$SUDO_USER` (account that ran `sudo`), or `$TARGET_USER` if running as root directly.

## A quiet bonus

Rootless Podman network through pasta/slirp4netns instead of bridge, so need *no* firewall changes. Default-deny firewall from `harden.sh` just work. Rootful Docker would need extra `forward` rules poked into firewall. One more win for rootless path.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` show every step (install, subuid allocation, linger, Quadlet directory) without applying.

Ran on amd64. Podman-version warning = thing to watch on first real Armbian run — that where you likely meet 4.3.