# `setup/podman.sh` explained

Plain-language walkthrough of the container-host stage. If you just want to use
it, the README is enough — this is the "why is it built this way" version.

## What it's for

Running programs in boxes. A **container** is an app packed up with everything it
needs — its own libraries, its own files — sealed in a box so it can't fight with
anything else on the machine. Want to run some self-hosted web app? Put it in a
container and it can't break the rest of your system. Podman is the tool that
runs those boxes.

## Why Podman, not Docker

Two reasons that matter a lot on a small, always-on box:

**Rootless.** Docker's engine runs as *root*, the all-powerful user — so if
something escapes a container, it escapes as root, owning your whole machine.
Podman runs containers as *you*, an ordinary user. Something that escapes is a
nobody with no power. Much safer default.

**Daemonless.** Docker keeps a program running in the background 24/7, waiting to
manage containers, eating memory even when nothing's happening. Podman has no
such background process — it just launches containers directly. On a 2 GB board,
that saved memory is real.

## The three things that must all be true

Rootless containers are great, but they fail in *baffling* ways if any one of
three setup steps is missing. The script does all three:

1. **A subuid/subgid range.** For your user to run containers, the system has to
   lend you a block of ~65,000 "pretend" user IDs to hand out inside containers.
   Without that block, every single `podman run` dies with a cryptic `newuidmap`
   error. And after adding the block, you have to run `podman system migrate`,
   because Podman already cached the old (empty) answer and won't notice
   otherwise. The script handles both.

2. **Lingering.** Normally, when you log out, Linux tears down everything you had
   running — which would kill your containers on every reboot, since a headless
   box has nobody logged in. `loginctl enable-linger` tells the system "let this
   user's services keep running even with nobody logged in." Without it, nothing
   survives a restart.

3. **Podman 4.4 or newer**, for **Quadlet**. Quadlet is the modern magic: you
   write a tiny text file describing a container, drop it in a folder, and
   *systemd* — the thing that already starts everything else on your machine —
   runs it like any other service. Boot-time startup, auto-restart, logs, all for
   free, no extra tools. But it needs Podman ≥ 4.4. Debian bookworm ships 4.3, so
   the script installs Podman anyway and *warns* you rather than pretending. On
   that version you'd use the older `podman generate systemd` instead.

## Who it configures

The box's *human owner*, not root — because the whole point is rootless. It
figures out who that is from `$SUDO_USER` (the account that ran `sudo`), or
`$TARGET_USER` if you're running as root directly.

## A quiet bonus

Because rootless Podman networks through pasta/slirp4netns instead of a bridge,
it needs *no* firewall changes. The default-deny firewall from `harden.sh` just
works. Rootful Docker would have needed extra `forward` rules poked into the
firewall. One more win for the rootless path.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` shows every step (install, subuid allocation, linger, Quadlet
  directory) without applying it.

Ran on amd64. The Podman-version warning is exactly the thing to watch on the
first real Armbian run, since that's where you'll likely meet 4.3.
