# nas-observability

Self-hosted observability stack for a single Synology NAS — metrics (Prometheus), logs and real-user monitoring (Loki + Alloy), all through one Grafana, on Docker Compose, with dashboards baked into a custom Grafana image.

## What it is

nas-observability is a self-hosted, unified observability stack for Synology NAS systems and any Docker containers running on them, spanning three pillars through a single Grafana pane of glass:

- **Metrics** — Prometheus plus standard exporters (node_exporter, cAdvisor, snmp_exporter, postgres_exporter).
- **Logs** — Grafana Loki for aggregation, Grafana Alloy as the collector (container logs via the Docker socket + host log files).
- **Real-user monitoring (RUM)** — Alloy's Faro receiver ingests frontend telemetry (logs, exceptions, events, measurements) from consumer web apps.

Dashboards and datasource provisioning are baked into a custom Grafana image. It's designed for single-NAS homelab use, not multi-host enterprise monitoring. Consumers (such as the Mneme PKM system) expose `/metrics` endpoints and emit Faro beacons; nas-observability scrapes/ingests them, owns their dashboards under `dashboards/<app>/`, and provides operational visibility. Distributed tracing / APM (Tempo) is deliberately out of scope — the Faro receiver drops trace signals in code until a future feature wires a trace backend.

## Stack

**Metrics stack** (`docker-compose.yml`, six services, ≤ 600 MB):

| Component         | Image                                                       | Purpose                                              |
|-------------------|-------------------------------------------------------------|------------------------------------------------------|
| Prometheus        | `prom/prometheus:v3.1.0`                                    | TSDB and scraping                                    |
| Grafana           | `ghcr.io/mstellaris/nas-observability/grafana:v0.3.0`       | Dashboards + datasources (custom image with baked provisioning; Prometheus + Loki datasources) |
| cAdvisor          | `gcr.io/cadvisor/cadvisor:v0.49.1`                          | Per-container metrics                                |
| node_exporter     | `prom/node-exporter:v1.8.2`                                 | Host-level metrics                                   |
| snmp_exporter     | `prom/snmp-exporter:v0.28.0`                                | Synology NAS metrics via SNMPv2c (CPU, RAM, disks, temperature) |
| postgres_exporter | `quay.io/prometheuscommunity/postgres-exporter:v0.16.0`     | Postgres metrics for consumer apps (Mneme today; reusable for future Postgres-backed consumers) |

**Logs/RUM stack** (`docker-compose.logs.yml`, two services, ≤ 500 MB):

| Component         | Image                                                       | Purpose                                              |
|-------------------|-------------------------------------------------------------|------------------------------------------------------|
| Loki              | `grafana/loki:3.3.2`                                       | Log aggregation (single-binary, filesystem + TSDB shipper, schema v13, 7-day retention) |
| Alloy             | `grafana/alloy:v1.5.1`                                     | Collector — container/host logs → Loki, plus the Faro receiver for frontend RUM |

Both stacks are deployed via Docker Compose under Portainer (as two separate Portainer stacks) on a Synology DS224+ running DSM 7.3. Loki and Alloy carry their config via runtime bind mounts, so they stay upstream-pinned — Grafana remains the sole custom image.

## Design constraints

These are hard caps enforced at every PR, not aspirations. See [`.specify/memory/constitution.md`](.specify/memory/constitution.md) for the full set of principles.

- **Two subsystem RAM budgets** — metrics ≤ 600 MB, logs/RUM ≤ 500 MB — kept legibly separate. Every service declares an explicit `mem_limit`; the relevant subsystem's sum is verified in the PR compliance checklist.
- **30-day Prometheus retention** plus a 5 GB TSDB size cap; **7-day Loki log retention** (compactor-enforced) plus a disk-watch. Hitting a cap is a cardinality/volume-regression signal, not a reason to expand.
- **Host networking throughout.** A deliberate response to DSM 7.3 bridge limitations, not an oversight. Every bound port is tracked in [`docs/ports.md`](docs/ports.md).
- **Upstream-first.** Pinned upstream images everywhere; a custom image only for Grafana, to bake in repo-owned provisioning. No forks.
- **Silent-by-default alerting.** Dashboards are the primary surface; email delivery is opt-in and reserved for a narrow set of critical events.

## Status

**Feature 001 — Infrastructure Bootstrap:** complete (2026-04-24). The baseline observability stack (Prometheus, Grafana, cAdvisor, node_exporter) running on the DS224+. Retrospective: [`specs/001-infrastructure-bootstrap/retrospective.md`](specs/001-infrastructure-bootstrap/retrospective.md).

**Feature 002 — Synology SNMP Scraping & Dashboards:** complete (2026-04-25). Adds an SNMP exporter that scrapes the NAS via SNMPv2c plus three baked Grafana dashboards (NAS Overview, Storage & Volumes, Network & Temperature). Also lands `scripts/diagnose.sh` (one-command stack diagnostic) and the GHA Node.js 24 migration. 24-hour stability observation passed with no scrape-duration drift and no NAS CPU footprint. Retrospective: [`specs/002-synology-nas-scraping/retrospective.md`](specs/002-synology-nas-scraping/retrospective.md).

**Feature 003 — Mneme Application Scraping & Dashboards:** complete (2026-04-26). Adds postgres_exporter for Mneme's database, three Mneme scrape jobs (api/worker/postgres), and three baked Grafana dashboards (Mneme — API, Worker, Database) under a per-application Architecture B layout. Migrates the flat `dashboards/` directory to per-domain subfolders (`stack/`, `synology/`, `mneme/`) with `foldersFromFilesStructure` provisioning. Adds a `honor_labels` count-gate CI step that machine-enforces the consumer-vs-generic-exporter discrimination per scrape job. Constitution amended to v1.2.0 (per-application Architecture B replaced the original cross-repo dashboard-sync workflow). 24-hour stability observation passed with no scrape-duration drift across all three Mneme jobs. Retrospective: [`specs/003-mneme-app-scraping/retrospective.md`](specs/003-mneme-app-scraping/retrospective.md).

**Feature 004 — Logs & RUM Subsystem (Loki + Alloy + Faro receiver):** complete (2026-05-31). The project's largest scope expansion — metrics-only → metrics + logs + RUM — gated by a constitutional amendment to v1.3.0 (Principle IV split into two subsystem budgets; new `3100–3199` port range; APM/Tempo deferral enforced in code). Adds a second Portainer stack (`docker-compose.logs.yml`): Loki (200 MB, 7-day retention) + Alloy (250 MB), within the new ≤ 500 MB logs/RUM cap. Alloy runs three pipelines — container logs (Docker-socket discovery), host log files, and a `faro.receiver` for frontend RUM (native API key, two-origin CORS, trace-drop). Grafana bumped v0.2.1 → v0.3.0 to bake the Loki datasource (`uid: loki`); F001–F003 dashboards render unchanged. Both pillars verified on live traffic (Mneme pino backend logs + a synthetic Faro beacon); the Faro receiver contract was published into Mneme's `docs/observability.md`, unparking Mneme F012. A post-close fix (`fef77ef`) promotes the Faro `app_name` body field to the `service_name` label so real beacons land queryable under `{service_name="mneme-frontend"}` instead of `unknown_service`. Retrospective: [`specs/004-logs-rum/retrospective.md`](specs/004-logs-rum/retrospective.md).

Combined scope shipped (F001–F004): an eight-service deployment across two stacks — six-service metrics stack at the 600 MB cap (cAdvisor + node_exporter trimmed to fund postgres_exporter) plus a two-service logs/RUM stack at 450 MB — seven baked Grafana dashboards across three folders rendering live data, Prometheus + Loki datasources, full DSM-side runbooks for SNMP enablement, Mneme metrics-user provisioning, and logs/RUM bring-up, and an operator-side diagnostic tool covering all eight services. Things still not shipped: Alertmanager (dedicated alerting feature), external-access reverse proxy (separate feature), distributed tracing / APM (Tempo, deferred), and frontend-symbolication (deferred — see Roadmap).

## Getting started

This repo is not designed for casual adoption — it's an opinionated stack with paths and UIDs pinned to a specific Synology layout. If you're forking it for a different NAS or different account, expect to edit the image namespace and the `/volume1/docker/observability/` paths.

- First-time deploy on the DS224+: [`docs/setup.md`](docs/setup.md)
- Updating images, dashboards, or scrape config: [`docs/deploy.md`](docs/deploy.md)
- Per-feature DSM-side enablement runbooks: [`docs/snmp-setup.md`](docs/snmp-setup.md) (F002) · [`docs/mneme-setup.md`](docs/mneme-setup.md) (F003) · [`docs/logs-setup.md`](docs/logs-setup.md) (F004)
- Port allocation table: [`docs/ports.md`](docs/ports.md)
- PR compliance checklist: [`.github/pull_request_template.md`](.github/pull_request_template.md)

## Methodology

Work follows the [spec-kit](https://github.com/github/spec-kit) flow: constitution → specify → plan → tasks → implement. Per-feature specs live under `specs/001-*/`, `specs/002-*/`, etc. Each feature's `spec.md` cites which constitutional principles it invokes when making tradeoffs.

The current constitution is at version 1.3.0 (ratified 2026-04-23; amended 2026-04-25 for v1.1's DSM platform constraints, 2026-04-26 for v1.2's per-application Architecture B, and 2026-05-31 for v1.3's expansion to metrics + logs + RUM with two subsystem budgets); see [`.specify/memory/constitution.md`](.specify/memory/constitution.md).

## Roadmap

- **F001** — Infrastructure bootstrap. The baseline stack observing itself and the host. *Complete (2026-04-24).*
- **F002** — Synology SNMP scraping, NAS dashboards (CPU, RAM, disk, temperature, volumes, network), `scripts/diagnose.sh`, GHA Node.js 24 migration. *Complete (2026-04-25).*
- **F003** — Mneme application scraping (api + worker + Postgres via postgres_exporter), three Mneme dashboards under per-app Architecture B (`dashboards/mneme/`), subfolder migration of F001/F002 dashboards (`stack/`, `synology/`), `honor_labels` CI count-gate, dashboard-export-noise strip script. Constitution v1.2 amendment placed dashboard authoring inside this repo (Architecture B replaced the originally-planned cross-repo dashboard sync — the deferred nightly GHA `schedule:` trigger from F001 was made obsolete by this and dropped). *Complete (2026-04-26).*
- **F004** — Logs & RUM subsystem: Grafana Loki + Grafana Alloy as a second Portainer stack (`docker-compose.logs.yml`), Alloy's Faro receiver for frontend RUM, Grafana v0.3.0 with a baked Loki datasource, `docs/logs-setup.md` runbook, and the cross-repo Faro contract that unparked Mneme F012. First feature under constitution v1.3.0 (metrics + logs + RUM, two subsystem budgets). *Complete (2026-05-31).*
- **F005+** — Next metrics consumer (Pinchflat / Immich / Home Assistant / etc.) following F003's per-application template: subfolder under `dashboards/<app>/`, scrape jobs with appropriate `honor_labels` setting, integration contract owned in the consumer repo while dashboards live here. (APM / GlitchTip-style error tracking, if it ever lands, is also an F005+ slot — contingent on a Mneme APM decision and a NAS deployment.)
- **Alerting feature** (unscheduled) — Alertmanager plus optional SMTP delivery for a narrow set of critical alerts. Lands once there are enough consumer apps to make silent-alert-only untenable.
- **Distributed tracing / APM** (deferred, out of scope) — Tempo or equivalent. The Faro receiver already drops trace signals in code (the v1.3 APM-deferral seam); a future feature flips the receiver to forward and wires a trace backend.
- **frontend-symbolication** (deferred, low criticality) — *Paired cross-repo feature with Mneme; the sending half is already shipped (Mneme F012).* Makes Mneme's frontend error stacks readable in Loki. Today F004's pipeline (Faro receiver → Alloy → Loki) stores frontend exception stacks verbatim — i.e. minified (`index-jQk4oDYt.js:29:53618`), because the receiver is telemetry-only with no source-map store or symbolication path (confirmed during Mneme F012's T005 gate). This feature de-minifies frames to source locations (`ErrorBoundary.tsx:42`). **Split:** the Mneme side is done — F012 generates hidden source maps keyed by bundle hash and emits Faro beacons carrying `gitHash`/`app_version` (the release key); Mneme's only remaining work is uploading those maps to wherever this repo decides they live (small). This repo owns the real, build-from-scratch work: (a) a per-release source-map store keyed by `gitHash` to receive + retain the uploaded maps; (b) a symbolication step with an undecided design fork — **symbolicate-at-ingest** (an Alloy processor resolves frames before the Loki write so Loki stores readable stacks; cost: ingest-time processing + the right release's map must be present at ingest) vs **symbolicate-at-read** (Loki keeps raw minified, a Grafana datasource/panel resolves at query time; cost: query-side tooling + every read re-resolves) — decide the fork at this feature's `/plan`. Grafana Cloud Frontend Observability offers this turnkey, but Mneme's NFR-34 and this stack's self-hosted posture rule out Cloud, so it's the harder custom self-hosted path. **Criticality: low** — not a capture gap. Mneme's frontend errors already land queryable here (`service_name="mneme-frontend"`, the boundary's componentStack as a distinct field, RUM flowing); symbolication only improves *reading* a captured error, and at single-user scale prod errors are usually reproducible locally with dev source maps, so the minified stack is a rare-case fallback. **Build gate:** a cross-repo integration check — Mneme generates → uploads → this repo stores → symbolicates → readable in Loki — verifiable only in the integrated system. It's load-bearing the same way F012's own T005 gate was: that gate caught a real defect (Mneme beacons landing as `unknown_service` because this repo's Alloy wasn't relabeling `app_name`→`service_name`; fix was here, surfaced only by a live beacon traversing the full pipe). Mirrors the backlog entry in Mneme's `docs/ROADMAP.md`; fuller design detail in Mneme's `docs/FEATURE-012-SHIPPED.md` retro.

## License

Not yet licensed. Treat as "all rights reserved" until a LICENSE file lands. The stack is personal infrastructure and not intended for redistribution; if you want to use it as a template, open an issue.

## Repository layout

```
nas-observability/
├── docker-compose.yml                       # Metrics stack (6 services, network_mode: host)
├── docker-compose.logs.yml                  # Logs/RUM stack (Loki + Alloy, network_mode: host)
├── config/
│   ├── prometheus/prometheus.yml            # Scrape jobs (4 stack + 3 Mneme)
│   ├── snmp_exporter/snmp.yml.template      # Synology SNMP module (rendered on NAS)
│   ├── loki/loki-config.yaml                # Loki single-binary config (7-day retention)
│   └── alloy/config.alloy                   # Alloy pipelines (container/host logs + Faro receiver)
├── docker/grafana/
│   ├── Dockerfile                           # Custom Grafana image build context
│   ├── dashboards/{stack,synology,mneme}/   # Per-domain dashboards (foldersFromFilesStructure)
│   └── provisioning/                        # Datasources (Prometheus + Loki) + dashboard provider
├── scripts/
│   ├── init-nas-paths.sh                    # One-time NAS-side bind-mount init + config render
│   ├── diagnose.sh                          # One-command stack diagnostic (all 8 services)
│   └── strip-grafana-export-noise.sh        # Cleans Grafana JSON exports before commit
├── docs/                                    # Setup, deploy, port allocation, per-feature runbooks
├── .github/                                 # CI workflows (Grafana image build + honor_labels gate) + PR template
├── .specify/memory/constitution.md          # Project governance (v1.3.0)
└── specs/                                   # Feature specs (spec-kit methodology)
```
