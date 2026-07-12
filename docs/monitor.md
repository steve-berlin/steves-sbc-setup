# `setup/monitor.sh` explained

Plain-language walkthrough of monitoring stage. Want just use it? README enough — this the "why built this way" version.

## What it's for

Gauge cluster for box. Installs `node_exporter`, small program that constantly publishes machine numbers — CPU load, memory used, temperature, disk space, network traffic — on port 9100. Point Prometheus and Grafana at it from another computer, get live graphs of SBC health.

Why separate exporter, not built-in dashboard? Tiny (~15 MB memory), industry-standard. Heavy graphing lives on *other* machine; SBC just reports vitals.

## The one subtle thing: who can see the numbers

`node_exporter` publishes to *everyone*, on every network interface — binds `0.0.0.0:9100`, meaning "all addresses." Alone, that puts machine internals on public display.

What keeps it private: **firewall from `harden.sh`**. Default-deny ruleset drops everything except short guest list — one item on list is "anything over Tailscale." Net effect: metrics visible over private Tailscale tunnel, invisible to public internet. Exporter not secured by *itself*; secured by firewall around it.

So this script checks firewall actually loaded, warns loudly if not — without it, port 9100 really world-readable.

## The tempting "fix" that doesn't work

Tempting: bind exporter *only* to Tailscale address, belt-and-braces. But that address doesn't *exist* yet when service starts at boot — Tailscale not up. Service would fail to start. Firewall approach the one that works, so it the one used. (Noted in CLAUDE.md so nobody "improves" it into breakage.)

## Why the stage order matters

Runs *after* `harden.sh`, depends on it. Firewall must already be in place, or exporter exposed moment it starts. Build walls before open windows.

## How it was checked

- `shellcheck -x` clean.
- `--dry-run` shows install and enable steps, plus firewall warning logic, without applying anything.