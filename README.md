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

**Feature 001 — Infrastructure Bootstrap:** complete (2026-04-24). The baseline observability stack (Prometheus, Grafana, cAdvisor, node_exporter) running on the DS224+. Retrospective: [`specs/001-infrastructure-bootstrap/retrospective.md`](specs/001-infrastructure-bootstrap/retrospective.md).

**Feature 002 — Synology SNMP Scraping & Dashboards:** complete (2026-04-25). Adds an SNMP exporter that scrapes the NAS via SNMPv2c plus three baked Grafana dashboards (NAS Overview, Storage & Volumes, Network & Temperature). Also lands `scripts/diagnose.sh` (one-command stack diagnostic) and the GHA Node.js 24 migration. 24-hour stability observation passed with no scrape-duration drift and no NAS CPU footprint. Retrospective: [`specs/002-synology-nas-scraping/retrospective.md`](specs/002-synology-nas-scraping/retrospective.md).

Combined scope shipped (F001 + F002): five-service stack at the 600 MB constitutional cap, four Grafana dashboards rendering live data, full DSM-side runbooks for SNMP enablement, and an operator-side diagnostic tool. Things still not shipped: application scraping (Feature 003+), Alertmanager (dedicated alerting feature), and external-access reverse proxy (separate feature).

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
- **F002** — Synology SNMP scraping, NAS dashboards (CPU, RAM, disk, temperature, volumes, network), `scripts/diagnose.sh`, GHA Node.js 24 migration. *Complete (2026-04-25).*
- **F003+** — Application scraping (first consumer: Mneme), with per-app dashboards pulled into the Grafana image at build time via CI. The deferred nightly GHA `schedule:` trigger ships here alongside the consumer-dashboard sync step it serves.
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
