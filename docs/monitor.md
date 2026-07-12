# `setup/monitor.sh` explained

Plain-language walkthrough of the monitoring stage. If you just want to use it,
the README is enough — this is the "why is it built this way" version.

## What it's for

A gauge cluster for the box. It installs `node_exporter`, a small program that
constantly publishes numbers about the machine — CPU load, memory used,
temperature, disk space, network traffic — on port 9100. Point a Prometheus and
Grafana at it from another computer and you get live graphs of how your SBC is
doing.

Why a separate exporter instead of a built-in dashboard? Because it's tiny
(~15 MB of memory) and it's the industry-standard way to do this. The heavy
graphing lives on some *other* machine; the SBC just quietly reports its vitals.

## The one subtle thing: who can see the numbers

`node_exporter` publishes to *everyone*, on every network interface — it binds
`0.0.0.0:9100`, meaning "all addresses." On its own, that would put your machine's
internals on public display.

What keeps it private is **the firewall from `harden.sh`**. That default-deny
ruleset drops everything except a short guest list — and one item on that list is
"anything over Tailscale." The net effect: your metrics are visible over your
private Tailscale tunnel, and invisible to the public internet. The exporter
isn't secured by *itself*; it's secured by the firewall around it.

So this script checks that a firewall is actually loaded, and warns loudly if
it isn't — because without it, port 9100 really is world-readable.

## The tempting "fix" that doesn't work

You might think: why not just bind the exporter *only* to the Tailscale address,
belt-and-braces? Because that address doesn't *exist* yet when the service starts
at boot — Tailscale hasn't come up. The service would fail to start. The firewall
approach is the one that actually works, which is why it's the one used. (This is
noted in CLAUDE.md so nobody "improves" it into breakage.)

## Why the stage order matters

Runs *after* `harden.sh`, and depends on it. The firewall must already be in
place, or the exporter is exposed the moment it starts. Set up the walls before
you open the windows.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` shows the install and enable steps, plus the firewall warning
  logic, without applying anything.
