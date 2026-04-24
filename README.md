# nas-observability

Self-hosted observability stack for a single Synology NAS — Prometheus, Grafana, and standard exporters on Docker Compose, with dashboards baked into a custom Grafana image.

## What it is

nas-observability is a self-hosted observability stack for Synology NAS systems and any Docker containers running on them. It combines Prometheus, Grafana, and standard exporters (node_exporter, cAdvisor, snmp_exporter) into a single Docker Compose deployment, with dashboards and alert rules baked into a custom Grafana image. It's designed for single-NAS homelab use, not multi-host enterprise monitoring. Consumers (such as the Mneme PKM system) expose `/metrics` endpoints; nas-observability scrapes them and provides operational visibility.

## Stack

| Component      | Image                                     | Purpose                                  |
|----------------|-------------------------------------------|------------------------------------------|
| Prometheus     | `prom/prometheus:v3.1.0`                  | TSDB and scraping                        |
| Grafana        | `ghcr.io/mstellaris/nas-observability/grafana:v0.1.0` | Dashboards (custom image with baked provisioning) |
| cAdvisor       | `gcr.io/cadvisor/cadvisor:v0.49.1`        | Per-container metrics                    |
| node_exporter  | `prom/node-exporter:v1.8.2`               | Host-level metrics                       |

Deployed via Docker Compose under Portainer on a Synology DS224+ running DSM 7.3.

## Design constraints

These are hard caps enforced at every PR, not aspirations. See [`.specify/memory/constitution.md`](.specify/memory/constitution.md) for the full set of principles.

- **600 MB total RAM budget** across all services. Every service declares an explicit `mem_limit`; the sum is verified in the PR compliance checklist.
- **30-day Prometheus retention** plus a 5 GB TSDB size cap. Hitting the size cap is a cardinality-regression signal, not a reason to expand.
- **Host networking throughout.** A deliberate response to DSM 7.3 bridge limitations, not an oversight. Every bound port is tracked in [`docs/ports.md`](docs/ports.md).
- **Upstream-first.** Pinned upstream images everywhere; a custom image only for Grafana, to bake in repo-owned provisioning. No forks.
- **Silent-by-default alerting.** Dashboards are the primary surface; email delivery is opt-in and reserved for a narrow set of critical events.

## Status

**Feature 001 — Infrastructure Bootstrap:** complete (2026-04-24). Deployed and running on the DS224+; memory observation (T027) passed with 60% headroom across the whole stack budget. Retrospective with the 13 DSM-specific fixes that surfaced during first deploy: [`specs/001-infrastructure-bootstrap/retrospective.md`](specs/001-infrastructure-bootstrap/retrospective.md).

What Feature 001 ships: compose stack with the four services above, a custom Grafana image with a baked `Stack Health` meta-dashboard, CI workflow publishing to GHCR on every push to `main`, and the authoritative port allocation table.

What it explicitly does not ship: Synology SNMP scraping (Feature 002), application scraping and app dashboards (Feature 003+), Alertmanager and email delivery (dedicated alerting feature), reverse proxy for external access (separate feature).

## Getting started

This repo is not designed for casual adoption — it's an opinionated stack with paths and UIDs pinned to a specific Synology layout. If you're forking it for a different NAS or different account, expect to edit the image namespace and the `/volume1/docker/observability/` paths.

- First-time deploy on the DS224+: [`docs/setup.md`](docs/setup.md)
- Updating images or rolling back: [`docs/deploy.md`](docs/deploy.md)
- Port allocation table: [`docs/ports.md`](docs/ports.md)
- PR compliance checklist: [`.github/pull_request_template.md`](.github/pull_request_template.md)

## Methodology

Work follows the [spec-kit](https://github.com/github/spec-kit) flow: constitution → specify → plan → tasks → implement. Per-feature specs live under `specs/001-*/`, `specs/002-*/`, etc. Each feature's `spec.md` cites which constitutional principles it invokes when making tradeoffs.

The current constitution is at version 1.0.0 (ratified 2026-04-23); see [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

## Roadmap

- **F001** — Infrastructure bootstrap. The baseline stack observing itself and the host. *Complete (2026-04-24).*
- **F002** — Synology SNMP scraping, Synology MIBs, and NAS-specific dashboards (CPU, RAM, disk, temperature, volumes).
- **F003+** — Application scraping (first consumer: Mneme), with per-app dashboards pulled into the Grafana image at build time via CI.
- **Alerting feature** (unscheduled) — Alertmanager plus optional SMTP delivery for a narrow set of critical alerts. Lands once there are enough consumer apps to make silent-alert-only untenable.

## License

Not yet licensed. Treat as "all rights reserved" until a LICENSE file lands. The stack is personal infrastructure and not intended for redistribution; if you want to use it as a template, open an issue.

## Repository layout

```
nas-observability/
├── docker-compose.yml               # The stack
├── config/prometheus/prometheus.yml # Scrape configuration
├── docker/grafana/                  # Custom Grafana image build context
├── scripts/init-nas-paths.sh        # One-time NAS-side bind-mount init
├── docs/                            # Setup, deploy, port allocation
├── .github/                         # CI workflow + PR template
├── .specify/memory/constitution.md  # Project governance
└── specs/                           # Feature specs (spec-kit methodology)
```
