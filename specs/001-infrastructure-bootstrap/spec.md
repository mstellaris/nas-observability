# Feature Specification: Infrastructure Bootstrap

**Feature Branch:** `001-infrastructure-bootstrap`
**Status:** Draft
**Created:** 2026-04-23
**Depends on:** Constitution v1.0.0 (ratified 2026-04-23)

---

## Overview

This is the foundational feature of the nas-observability stack. It stands up a deployable Docker Compose stack on the Synology DS224+ running Prometheus, Grafana, cAdvisor, and node_exporter — and wires the constitutional principles into that stack from day one, so every later feature inherits the discipline rather than retrofitting it.

When this feature ships, the operator has a live stack observing the host: Prometheus scraping three local exporters (itself, cAdvisor, node_exporter), a Grafana reachable on the home network with its Prometheus datasource provisioned, a placeholder "Stack Health" dashboard proving the custom-image build pipeline works end to end, and a CI workflow publishing tagged Grafana images to GHCR on every push to `main`. Total RAM consumption stays within the 600 MB constitutional cap, with explicit headroom reserved for Feature 002.

NAS-specific scraping (SNMP exporter, Synology MIBs, Synology dashboards) is **Feature 002**. Application integration (scraping Mneme `/metrics`, dashboard sync CI) is **Feature 003+**. Alertmanager and alert rules ship in a dedicated alerting feature later. This feature answers "is the stack alive and observing itself?" with "yes, and it's ready to observe anything we point it at."

---

## User Scenarios & Testing

### Primary User Story

As Stellar, I want to deploy a Docker Compose observability stack on the DS224+ via Portainer and reach a Grafana UI from the home network, so that I have a working foundation — pinned images, bound memory, host-port allocations, custom-image build pipeline, bind-mounted state — onto which Feature 002 can add Synology SNMP scraping without revisiting any of those decisions.

### Acceptance Scenarios

**Scenario 1: First deploy via Portainer succeeds**

**Given** the DSM-side prerequisites are in place (Container Manager installed, `/volume1/docker/observability/` created with correct ACLs, `.env` populated from `.env.example`)
**When** the operator creates a new Portainer stack pointing at this repo's `docker-compose.yml`
**Then** four containers start successfully (prometheus, grafana, cadvisor, node-exporter)
**And** each container is running with `network_mode: host`
**And** each container's memory usage is within its declared `mem_limit`
**And** all four containers carry a restart policy (`unless-stopped`) so they survive a NAS reboot

**Scenario 2: Prometheus scrapes the three local targets**

**Given** the stack is running
**When** the operator visits `http://<nas-host>:9090/targets`
**Then** three scrape targets are listed (`prometheus`, `cadvisor`, `node_exporter`)
**And** all three report state UP with a last-scrape timestamp within the configured scrape interval
**And** Prometheus's `/metrics` surfaces `prometheus_tsdb_*` metrics confirming the TSDB is writing blocks

**Scenario 3: Grafana loads with provisioned datasource**

**Given** the Grafana container is running from the custom GHCR image
**When** the operator visits `http://<nas-host>:3030` and logs in with the admin credentials from `.env`
**Then** a Prometheus datasource named `prometheus` is already present under Configuration → Data sources
**And** its health check passes against `http://localhost:9090` (host networking)
**And** the operator was not asked to configure it — it was provisioned at image-build time

**Scenario 4: Placeholder Stack Health dashboard renders**

**Given** Grafana is loaded
**When** the operator opens the `Stack Health` dashboard (baked into the image)
**Then** panels render showing `up{}` per scrape target, Prometheus's own scrape duration, and total series count in the TSDB
**And** the dashboard's build metadata (image tag = semver + short git SHA) is visible in its title or a stat panel
**And** the operator can confirm end-to-end that a JSON dashboard committed to this repo shipped via CI → GHCR → Grafana → browser

**Scenario 5: Memory limits are enforced**

**Given** the stack has been running for at least an hour
**When** the operator runs `docker stats --no-stream`
**Then** no container exceeds its declared `mem_limit`
**And** the sum of `mem_limit` values across all four services is ≤ 600 MB
**And** the sum of observed memory usage is also ≤ 600 MB

**Scenario 6: Prometheus retention is enforced**

**Given** Prometheus has been configured with `--storage.tsdb.retention.time=30d` and `--storage.tsdb.retention.size=5GB`
**When** either cap is reached
**Then** Prometheus prunes the oldest blocks automatically
**And** TSDB disk usage stabilizes rather than growing unbounded
**And** the retention settings are visible under Prometheus's `/flags` endpoint

**Scenario 7: Custom Grafana image builds and publishes on push**

**Given** a PR lands on `main` that changes the Grafana build context (dashboard JSON, provisioning YAML, or Dockerfile)
**When** the GitHub Actions workflow runs
**Then** the image builds successfully
**And** it is pushed to GHCR tagged with both a semver tag and the short git SHA
**And** the tag is recorded as an artifact / workflow output for traceability
**And** a subsequent Portainer redeploy pointing at the new tag pulls the new image and renders the updated dashboard

**Scenario 8: Bind-mounted state survives redeploy**

**Given** Prometheus has accumulated at least an hour of TSDB data and Grafana has been logged into at least once
**When** the operator stops the stack and redeploys it via Portainer
**Then** Prometheus resumes from its existing TSDB (no data loss, no re-init)
**And** Grafana's admin session state survives (data under `/var/lib/grafana` persisted to the host bind mount)
**And** the datasource and dashboard still render because they are provisioned from the image, not from state

**Scenario 9: Port allocation table is respected**

**Given** `docs/ports.md` declares the authoritative port ranges and current assignments
**When** a PR adds, moves, or removes a service's host port
**Then** the PR updates `docs/ports.md` in the same change
**And** the assigned port falls within one of the declared ranges
**And** the port does not collide with any previously-declared assignment or DSM's reserved ports (5000/5001 for DSM itself, 80/443 if in use)

**Scenario 10: Constitutional compliance gates block non-compliant PRs**

**Given** a PR adds a fifth service to the stack
**When** the reviewer runs through the compliance checklist
**Then** the PR is rejected unless it shows: (a) a pinned image version, (b) an explicit `mem_limit`, (c) that the total budget is still ≤ 600 MB (trimming other services if necessary), (d) an updated entry in `docs/ports.md`, (e) a documented host bind mount path if the service persists state

### Edge Cases

- **DSM ACL / bind-mount ownership gotcha.** Synology's DSM applies its own ACLs on top of Linux permissions; a `chown` alone isn't always enough. Bind-mounted directories need both `chown -R <uid>:<gid>` and explicit ACL handling (via DSM File Station → Properties → Permission, or `synoacltool`) for containers that run as non-root (Prometheus as `nobody:nobody` 65534:65534, Grafana as `grafana:grafana` 472:472). If missed, containers silently fail to write state. Documented explicitly in `docs/setup.md`.
- **Host port collision with DSM services.** DSM itself uses 5000/5001 (web UI) and may use 80/443 if the DSM reverse proxy is enabled. Our allocations avoid these ranges entirely; `docs/ports.md` calls out DSM's reserved ports as forbidden.
- **GHCR auth failure in CI.** The GitHub Actions workflow must authenticate with a token scoped to push to GHCR under this repo's namespace. Surface auth failures as clean CI errors, not mysterious "denied" messages.
- **Prometheus config typo.** A bad `prometheus.yml` causes the container to exit on start; the operator sees this in `docker logs` rather than a silent broken scrape. Compose healthchecks on Prometheus give Portainer a clear failure state.
- **Custom Grafana image pulled with `latest`.** Forbidden. The compose file references a specific semver tag, and the CI workflow publishes both semver and `sha-<short>` tags but never `latest`.
- **cAdvisor memory creep on DSM.** cAdvisor has a known appetite for memory on some kernels. The allocated budget assumes a conservative sample retention; if we see OOM kills in practice, the fix is to trim cAdvisor's `--storage_duration` flag, not to raise the `mem_limit` above the budgeted 90 MB.
- **Placeholder dashboard mistaken for production-ready.** The `Stack Health` dashboard is explicitly a meta-health view, not a NAS or app dashboard. Its title and description say so. Feature 002 adds real NAS dashboards; Feature 003+ adds app dashboards. `Stack Health` stays forever as a useful meta view.
- **Restart loop on first boot.** If bind-mount ACLs are wrong, containers restart in a loop. The `unless-stopped` policy plus clear `docker logs` output makes this diagnosable; `docs/setup.md` names this as the most likely first-deploy failure.

---

## Requirements

### Functional Requirements

- **FR-1:** The system MUST provide a single `docker-compose.yml` at the repo root declaring four services (`prometheus`, `grafana`, `cadvisor`, `node-exporter`), each with `network_mode: host`, a pinned image tag, an explicit `mem_limit`, and a `restart: unless-stopped` policy. [Constitution: Principles I, II, III, IV]
- **FR-2:** The Prometheus service MUST use the upstream `prom/prometheus` image at a pinned version, pulled from Docker Hub without modification. [Constitution: Principle I]
- **FR-3:** The cAdvisor service MUST use the upstream `gcr.io/cadvisor/cadvisor` image at a pinned version, pulled from its canonical registry without modification. [Constitution: Principle I]
- **FR-4:** The node_exporter service MUST use the upstream `prom/node-exporter` image at a pinned version, pulled from Docker Hub without modification. [Constitution: Principle I]
- **FR-5:** The Grafana service MUST use a custom image built from this repo's `docker/grafana/Dockerfile`, published to GHCR under this repo's namespace, and pinned in `docker-compose.yml` by semver tag (never `latest`). The image MUST be based on an upstream `grafana/grafana` tag and MUST limit its customization to baking in provisioning files and dashboard JSON — no forks, no plugin injection, no upstream patches. [Constitution: Principle I]
- **FR-6:** Prometheus MUST scrape three targets in Feature 001: itself (`localhost:9090`), cAdvisor (`localhost:8080`), and node_exporter (`localhost:9100`). Scrape targets MUST be expressed as `localhost` or the host IP, not container names (consequence of host networking). [Constitution: Principle III]
- **FR-7:** Prometheus MUST enforce retention via `--storage.tsdb.retention.time=30d` (hard time cap) and `--storage.tsdb.retention.size=5GB` (hard size cap). Whichever binds first prunes the oldest blocks. [Constitution: Principle IV]
- **FR-8:** The custom Grafana image MUST bake in, at minimum: (a) a Prometheus datasource provisioning YAML pointing at `http://localhost:9090`, (b) a dashboard provider config, (c) a single `Stack Health` dashboard JSON showing `up{}` per target, Prometheus scrape duration, and total TSDB series. The image tag (semver + short SHA) MUST be surfaced somewhere in the dashboard for traceability. [Constitution: Principles I, II]
- **FR-9:** A GitHub Actions workflow MUST build the Grafana image and push it to GHCR on every push to `main`. Images MUST be tagged with both a semver tag and a short-SHA tag (`sha-<7chars>`). The workflow MUST authenticate to GHCR using a token scoped to this repo. [Constitution: Principle II]
- **FR-10:** The repo MUST commit a `.env.example` documenting all required keys (at minimum: `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`). The actual `.env` MUST be gitignored. No secrets may be hardcoded in `docker-compose.yml`, Dockerfile, or provisioning files. [Constitution: Platform Constraints §Secrets]
- **FR-11:** Persistent state MUST live under bind mounts at `/volume1/docker/observability/` on the NAS. Specifically: `prometheus/data` → `/prometheus` (Prometheus TSDB), `grafana/data` → `/var/lib/grafana` (Grafana state). cAdvisor and node_exporter require the standard read-only host mounts but no writable state. [Constitution: Principle II]
- **FR-12:** The repo MUST commit `docs/setup.md` covering DSM-side prerequisites: Container Manager installation, creation of `/volume1/docker/observability/{prometheus,grafana}/data` with correct ownership (`nobody:nobody` for Prometheus, `472:472` for Grafana) and DSM ACL adjustments, and explicit note that SNMP enablement is deferred to Feature 002. [Constitution: Principle II]
- **FR-13:** The repo MUST commit `docs/deploy.md` covering the Portainer redeploy flow: point at this repo's compose file, set `.env` contents in Portainer's stack environment, redeploy with "pull latest image" to move between image tags, and rollback by repointing to a previous tag. [Constitution: Principle II]
- **FR-14:** The repo MUST commit `docs/ports.md` as the authoritative port allocation table. It MUST declare reserved ranges and current assignments per the table below, and MUST be updated in the same PR as any service addition or port change. [Constitution: Principle III]
- **FR-15:** Every PR that adds or modifies a service MUST satisfy the constitutional compliance checklist: pinned image version, explicit `mem_limit`, total budget ≤ 600 MB after the change, declared host port in `docs/ports.md`, and documented bind mount if the service persists state. [Constitution: Principle IV + Governance]

### Non-Functional Requirements

- **NFR-1:** Total Feature-001 memory allocation MUST sum to ≤ 560 MB, reserving ≥ 40 MB of the constitutional 600 MB cap for the SNMP exporter to be added in Feature 002. Allocation: **Prometheus 280 MB, Grafana 140 MB, cAdvisor 90 MB, node_exporter 50 MB = 560 MB** (see *Specific Decisions* below for rationale). [Constitution: Principle IV]
- **NFR-2a:** A warm-cache redeploy (images already pulled) MUST bring the stack to a healthy running state within 1 minute.
- **NFR-2b:** A cold-cache first deploy against an empty `/volume1/docker/observability/` MUST bring the stack to a healthy running state within 5 minutes, dominated by image pull time on residential bandwidth.
- **NFR-3:** Prometheus TSDB data MUST survive container restarts, stack redeploys, and NAS reboots. No re-initialization, no data loss.
- **NFR-4:** Grafana's provisioned datasource and baked dashboard MUST survive container restarts and image-tag updates without requiring any manual intervention.
- **NFR-5:** All services MUST carry a `restart: unless-stopped` policy so that a NAS reboot restores the full stack automatically.
- **NFR-6:** GHA build → GHCR publish for the Grafana image SHOULD complete in under 5 minutes on the standard GitHub-hosted runner. This is a soft target, intended to keep iteration fast.

### Key Entities

- **Stack:** the four-service Docker Compose deployment defined by this repo's `docker-compose.yml`, deployed via Portainer on the DS224+.
- **Custom Grafana image:** a GHCR-published image built from `docker/grafana/Dockerfile` that layers datasource provisioning, dashboard provisioning config, and baked dashboard JSON on top of an upstream Grafana version. Tagged `vX.Y.Z` and `sha-<short>`.
- **Port allocation table:** `docs/ports.md`. Authoritative source for which host ports the stack binds. Declares reserved ranges, not just current assignments.
- **Bind mount root:** `/volume1/docker/observability/` on the NAS. Houses per-service writable state directories with ACLs set for each container's running user.
- **Build pipeline:** the GitHub Actions workflow that rebuilds and republishes the custom Grafana image on every push to `main`. Bridges repo changes to deployable artifacts without manual image management.
- **Compliance checklist:** the five-point gate (pinned version, `mem_limit`, budget ≤ 600 MB, port table updated, bind mount documented) that every service-touching PR must pass.

---

## Specific Decisions (resolved in this spec)

These are the decisions the user required the spec to resolve rather than defer to `plan.md`.

### D1. Port allocation table v1

Reserved ranges (future features add to this table, never invent new ranges):

| Range       | Purpose                                    | Feature 001 assignments   | Reserved for later                           |
|-------------|--------------------------------------------|---------------------------|----------------------------------------------|
| 3000–3099   | UI services                                | `3030` Grafana            | future user-facing UIs                       |
| 8080–8099   | Container/exporter UIs                     | `8080` cAdvisor           | other UI-bearing exporters                   |
| 9090–9099   | Prometheus core and related                | `9090` Prometheus         | `9093` Alertmanager (future alerting feat.)  |
| 9100–9199   | Exporters                                  | `9100` node_exporter      | `9116` SNMP exporter (F002), `9187` postgres_exporter (F003+), other prom-ecosystem exporters |

**Forbidden ports (DSM reservations):** 80, 443 (if DSM reverse proxy is active), 5000, 5001 (DSM web UI), 22 (SSH). `docs/ports.md` names these explicitly.

### D2. Memory budget allocation — reserve SNMP headroom now

The user presented three options: (A) trim Feature 001 services when F002 arrives, (B) keep 600 MB exact and amend the budget at F002, (C) under-allocate F001 now and name the future occupant. This spec picks **Option C** because it respects Principle IV without requiring a constitutional amendment on every feature addition.

**Feature 001 allocation (total 560 MB):**

| Service        | `mem_limit` | Notes                                                            |
|----------------|-------------|------------------------------------------------------------------|
| Prometheus     | 280 MB      | TSDB in-memory head block + query engine; 4 targets is light     |
| Grafana        | 140 MB      | Single admin user, ~1 dashboard; real consumption typically 80–120 MB |
| cAdvisor       | 90 MB       | Per-container metrics collection. Fitting under 90 MB on DSM requires tuning from day one: aggressive `--storage_duration=1m` (vs. default 2m) and disabling unneeded collectors. This is not an optional optimization — 90 MB is infeasible at cAdvisor defaults. |
| node_exporter  | 50 MB       | Very light; 50 MB is generous                                    |
| **Reserved**   | **40 MB**   | **Earmarked for SNMP exporter (Feature 002)**                    |
| **Total cap**  | **600 MB**  | Constitution Principle IV                                        |

`plan.md` specifies the exact cAdvisor flags. If we cannot stay under 90 MB after tuning, the F002 PR trims another service rather than expanding the budget. Likewise, if Feature 002's SNMP exporter needs more than 40 MB, the correct path is to trim one of the F001 services in the F002 PR (with compliance-checklist justification), not to exceed the 600 MB cap.

### D3. Grafana image strategy — bake in a placeholder `Stack Health` dashboard

Between "empty image, provisioning only" and "placeholder dashboard baked in," this spec picks **baked-in placeholder**. Reasons:

1. It exercises the full pipeline — dashboard JSON → image build → GHCR push → Portainer pull → Grafana provisioning → browser render — end to end, so CI has something real to test.
2. `Stack Health` is not a throwaway. It's a meta-health view of the observability stack itself (`up{}` per target, scrape duration, TSDB series count, image tag) that stays useful forever. Feature 002 adds NAS dashboards alongside it, not replacing it.
3. It eliminates a category of "nothing happened" failures where provisioning silently misconfigures and no one notices until the first real dashboard arrives weeks later.

### D4. Bind mount host paths and ACL handling

Host paths:

- `/volume1/docker/observability/prometheus/data` → container `/prometheus` (Prometheus TSDB, read-write, owner `nobody:nobody` / 65534:65534)
- `/volume1/docker/observability/grafana/data` → container `/var/lib/grafana` (Grafana state, read-write, owner `472:472`)
- cAdvisor: read-only host mounts of `/`, `/var/run`, `/sys`, `/var/lib/docker/` (standard upstream recipe; no writable state)
- node_exporter: read-only host mount of `/` to `/host/root` with `--path.rootfs=/host/root` (standard upstream recipe; no writable state)

`docs/setup.md` documents both the `chown` step and the DSM ACL step (via File Station → Properties → Permission tab, or `synoacltool`), because a `chown` alone on DSM is often insufficient.

### D5. Prometheus retention configuration

- `--storage.tsdb.retention.time=30d` — constitutional ceiling (Principle IV).
- `--storage.tsdb.retention.size=5GB` — size cap calculated as follows. With Prometheus's typical compressed footprint of ~1–2 bytes per sample and F001's four scrape targets each producing ~200–400 time series at a 15s scrape interval, 30 days of data is on the order of 200–500 MB. With F002's SNMP exporter and F003+'s app exporters the footprint can grow 10–20×, but should remain comfortably under 5 GB for foreseeable scrape scale. 5 GB is a safety cap against runaway cardinality (misconfigured exporter producing high-cardinality series, accidental new label dimension, or WAL inflation from scrape retries) — not a tight ceiling. If we approach it in normal operation, that's a signal of an instrumentation regression to investigate, not a budget to expand.

---

## Success Criteria

This feature is complete when:

1. A fresh (cold-cache) Portainer deploy against an empty `/volume1/docker/observability/` brings up all four services within 5 minutes and all three Prometheus scrape targets report UP (per NFR-2b); warm-cache redeploys land within 1 minute (per NFR-2a).
2. Grafana is reachable on port 3030, login with `.env` credentials works, the Prometheus datasource is provisioned and healthy, and the `Stack Health` dashboard renders with live data.
3. The custom Grafana image is published to GHCR with both a semver tag and a short-SHA tag via the GHA workflow on every push to `main`.
4. `docker stats` over a 1-hour window confirms total stack RAM stays within the 560 MB allocation (and therefore the 600 MB constitutional cap).
5. Prometheus retention flags are visible at `/flags` and TSDB pruning behavior is observed (or trusted based on upstream documentation plus size-cap verification under load).
6. `docs/setup.md`, `docs/deploy.md`, and `docs/ports.md` are committed and accurate against the deployed stack.
7. `.env.example` enumerates required keys; `.env` is gitignored.
8. Stopping and redeploying the stack preserves TSDB data and Grafana state (bind mounts round-trip correctly).
9. The compliance checklist (pinned version, `mem_limit`, budget, port table, bind mount) is documented in `docs/deploy.md` or `CONTRIBUTING.md` and ready to gate Feature 002 PRs.

Explicitly not required for this feature:

- Any Synology-specific scraping or dashboards (Feature 002).
- Any application scraping or app dashboards (Feature 003+).
- Any alerting delivery, Alertmanager, or SMTP config (later alerting feature).
- Reverse-proxy-fronted Grafana with basic auth (separate feature once external-access design is decided).

---

## Out of Scope

- **SNMP exporter, Synology MIBs, Synology-specific dashboards** → Feature 002.
- **Application dashboards (Mneme, future apps)** and the **dashboard sync CI workflow** that pulls consumer `ops/dashboards/` into the Grafana image → Feature 003+. (The sync mechanism is described in the constitution; its implementation arrives with the first consumer.)
- **Alertmanager, alert rules, email delivery (SMTP)** → dedicated alerting feature after the first few consumer apps are onboarded.
- **postgres_exporter** → ships with whichever feature first introduces a Postgres-backed app to monitor (likely Feature 003, Mneme).
- **Caddy (or any reverse proxy) fronting Grafana** → separate feature, after external-access auth strategy is decided.
- **Multi-host or high-availability deployments.** Single-NAS, single-operator scope (Constitution §Platform).
- **External secret stores** (1Password, Vault). Constitution explicitly rules these out of scope.
- **Telegraf, InfluxDB, or alternate TSDB experiments.** Prometheus is the chosen TSDB per constitution.

---

## Notes for `/plan` and `/tasks`

When this feature is started, `plan.md` resolves the following (explicitly deferred from this spec):

- **Exact Dockerfile contents** for the custom Grafana image (base tag, copy directives, layer ordering, any build args for embedding the git SHA into the dashboard).
- **Exact `prometheus.yml` scrape intervals per target** (15s vs. 30s vs. 60s for each of Prometheus-self, cAdvisor, node_exporter) and evaluation intervals for when alerting lands later.
- **Exact GitHub Actions workflow YAML** — steps, action versions, triggers (`push: main` plus the nightly schedule promised for consumer-dashboard propagation, even though F001 has no consumer dashboards yet), GHCR auth approach, tag computation.
- **Exact `.env.example` key list** — F001's keys only; later features will add (SMTP, SNMPv3 credentials, per-app datasource credentials, etc.).
- **Exact cAdvisor command-line flags** — `--storage_duration`, `--housekeeping_interval`, disabling metrics we don't need to keep memory in the 90 MB allocation.
- **Exact `Stack Health` dashboard JSON** — panel list, queries, layout, how the image tag is surfaced (stat panel, title suffix, or annotation).
- **Bind mount initialization script or runbook** in `docs/setup.md` — whether to ship a `scripts/init-nas-paths.sh` runnable from the NAS, or document the `mkdir`/`chown`/DSM ACL steps manually.
- **`CONTRIBUTING.md` or embedded doc for the compliance checklist** — where it lives, whether a PR template enforces it, whether a simple linter script validates `mem_limit` sums against 600 MB.

And `tasks.md` will decompose the work into the obvious phases: (1) Compose skeleton + bind mounts + `.env` plumbing, (2) Prometheus config + scrape targets + retention flags, (3) custom Grafana image (Dockerfile + provisioning + `Stack Health` dashboard), (4) GHA workflow + GHCR publishing, (5) documentation (`setup.md`, `deploy.md`, `ports.md`, compliance checklist), (6) DS224+ deploy + acceptance scenarios walk-through.
