# nas-observability

Self-hosted observability stack for a single Synology NAS — Prometheus, Grafana, and standard exporters on Docker Compose, with dashboards baked into a custom Grafana image.

## What it is

nas-observability is a self-hosted observability stack for Synology NAS systems and any Docker containers running on them. It combines Prometheus, Grafana, and standard exporters (node_exporter, cAdvisor, snmp_exporter, postgres_exporter) into a single Docker Compose deployment, with dashboards and alert rules baked into a custom Grafana image. It's designed for single-NAS homelab use, not multi-host enterprise monitoring. Consumers (such as the Mneme PKM system) expose `/metrics` endpoints; nas-observability scrapes them, owns their dashboards under `dashboards/<app>/`, and provides operational visibility.

## Stack

| Component         | Image                                                       | Purpose                                              |
|-------------------|-------------------------------------------------------------|------------------------------------------------------|
| Prometheus        | `prom/prometheus:v3.1.0`                                    | TSDB and scraping                                    |
| Grafana           | `ghcr.io/mstellaris/nas-observability/grafana:v0.2.1`       | Dashboards (custom image with baked provisioning)    |
| cAdvisor          | `gcr.io/cadvisor/cadvisor:v0.49.1`                          | Per-container metrics                                |
| node_exporter     | `prom/node-exporter:v1.8.2`                                 | Host-level metrics                                   |
| snmp_exporter     | `prom/snmp-exporter:v0.28.0`                                | Synology NAS metrics via SNMPv2c (CPU, RAM, disks, temperature) |
| postgres_exporter | `quay.io/prometheuscommunity/postgres-exporter:v0.16.0`     | Postgres metrics for consumer apps (Mneme today; reusable for future Postgres-backed consumers) |

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

**Feature 003 — Mneme Application Scraping & Dashboards:** code complete (2026-04-25); 24h observation pending. Adds postgres_exporter for Mneme's database, three Mneme scrape jobs (api/worker/postgres), and three baked Grafana dashboards (Mneme — API, Worker, Database) under a per-application Architecture B layout. Migrates the flat `dashboards/` directory to per-domain subfolders (`stack/`, `synology/`, `mneme/`) with `foldersFromFilesStructure` provisioning. Adds a `honor_labels` count-gate CI step that machine-enforces the consumer-vs-generic-exporter discrimination per scrape job. Constitution amended to v1.2.0 (per-application Architecture B replaced the original cross-repo dashboard-sync workflow). Retrospective: [`specs/003-mneme-app-scraping/retrospective.md`](specs/003-mneme-app-scraping/retrospective.md).

Combined scope shipped (F001 + F002 + F003): six-service stack at the 600 MB constitutional cap (cAdvisor + node_exporter trimmed to fund postgres_exporter), seven Grafana dashboards across three folders rendering live data, full DSM-side runbooks for SNMP enablement and Mneme metrics-user provisioning, and an operator-side diagnostic tool. Things still not shipped: Alertmanager (dedicated alerting feature) and external-access reverse proxy (separate feature).

## Getting started

This repo is not designed for casual adoption — it's an opinionated stack with paths and UIDs pinned to a specific Synology layout. If you're forking it for a different NAS or different account, expect to edit the image namespace and the `/volume1/docker/observability/` paths.

- First-time deploy on the DS224+: [`docs/setup.md`](docs/setup.md)
- Updating images, dashboards, or scrape config: [`docs/deploy.md`](docs/deploy.md)
- Per-feature DSM-side enablement runbooks: [`docs/snmp-setup.md`](docs/snmp-setup.md) (F002) · [`docs/mneme-setup.md`](docs/mneme-setup.md) (F003)
- Port allocation table: [`docs/ports.md`](docs/ports.md)
- PR compliance checklist: [`.github/pull_request_template.md`](.github/pull_request_template.md)

## Methodology

Work follows the [spec-kit](https://github.com/github/spec-kit) flow: constitution → specify → plan → tasks → implement. Per-feature specs live under `specs/001-*/`, `specs/002-*/`, etc. Each feature's `spec.md` cites which constitutional principles it invokes when making tradeoffs.

The current constitution is at version 1.2.0 (ratified 2026-04-23; amended 2026-04-25 for v1.1's DSM platform constraints and v1.2's per-application Architecture B); see [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

## Roadmap

- **F001** — Infrastructure bootstrap. The baseline stack observing itself and the host. *Complete (2026-04-24).*
- **F002** — Synology SNMP scraping, NAS dashboards (CPU, RAM, disk, temperature, volumes, network), `scripts/diagnose.sh`, GHA Node.js 24 migration. *Complete (2026-04-25).*
- **F003** — Mneme application scraping (api + worker + Postgres via postgres_exporter), three Mneme dashboards under per-app Architecture B (`dashboards/mneme/`), subfolder migration of F001/F002 dashboards (`stack/`, `synology/`), `honor_labels` CI count-gate, dashboard-export-noise strip script. Constitution v1.2 amendment placed dashboard authoring inside this repo (Architecture B replaced the originally-planned cross-repo dashboard sync — the deferred nightly GHA `schedule:` trigger from F001 was made obsolete by this and dropped). *Code complete (2026-04-25); 24h observation pending.*
- **F004+** — Next consumer (Pinchflat / Immich / Home Assistant / etc.) following F003's per-application template: subfolder under `dashboards/<app>/`, scrape jobs with appropriate `honor_labels` setting, integration contract owned in the consumer repo while dashboards live here.
- **Alerting feature** (unscheduled) — Alertmanager plus optional SMTP delivery for a narrow set of critical alerts. Lands once there are enough consumer apps to make silent-alert-only untenable.

## License

Not yet licensed. Treat as "all rights reserved" until a LICENSE file lands. The stack is personal infrastructure and not intended for redistribution; if you want to use it as a template, open an issue.

## Repository layout

```
nas-observability/
├── docker-compose.yml                       # The stack (6 services, network_mode: host)
├── config/
│   ├── prometheus/prometheus.yml            # Scrape jobs (4 stack + 3 Mneme)
│   └── snmp_exporter/snmp.yml.template      # Synology SNMP module (rendered on NAS)
├── docker/grafana/
│   ├── Dockerfile                           # Custom Grafana image build context
│   ├── dashboards/{stack,synology,mneme}/   # Per-domain dashboards (foldersFromFilesStructure)
│   └── provisioning/                        # Datasources + dashboard provider
├── scripts/
│   ├── init-nas-paths.sh                    # One-time NAS-side bind-mount init + config render
│   ├── diagnose.sh                          # One-command stack diagnostic
│   └── strip-grafana-export-noise.sh        # Cleans Grafana JSON exports before commit
├── docs/                                    # Setup, deploy, port allocation, per-feature runbooks
├── .github/                                 # CI workflows (Grafana image build + honor_labels gate) + PR template
├── .specify/memory/constitution.md          # Project governance (v1.2.0)
└── specs/                                   # Feature specs (spec-kit methodology)
```
