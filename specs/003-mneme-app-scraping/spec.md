# Feature Specification: Mneme Application Scraping & Dashboards

**Feature Branch:** `003-mneme-app-scraping`
**Status:** Draft
**Created:** 2026-04-26
**Depends on:** Feature 002 complete (2026-04-25); Constitution v1.2.0 (amended 2026-04-26); Mneme F008 T001-T009 deployed on the NAS (instrumentation backbone live at `localhost:3000/metrics` and `localhost:3001/metrics`); Mneme F008 T013 (`docs/observability.md`) **pending in Mneme parallel work stream — F003 PR cannot merge until T013 has landed and been cross-read against v1.2**.

---

## Overview

Feature 003 turns the NAS observability stack into something that observes the *applications* running on the NAS, not just the NAS itself. F002 left us with a stack that scrapes Synology hardware metrics and itself; F003 adds the first per-application consumer — Mneme — and establishes the patterns future consumers (Pinchflat, Immich, Home Assistant, etc.) will follow when they're added in F004+.

F003 is the first feature implemented under Constitution v1.2's Architecture B: dashboards for application consumers live in *this* repository under `docker/grafana/dashboards/<consumer-slug>/`, baked at image-build time. Mneme owns its `/metrics` contract (the metric names, labels, semantics, and now-pending integration documentation in Mneme's `docs/observability.md`); this repository owns the visualization layer (and the alerting layer when that ships). Three dashboards land in F003: Mneme API health, Mneme worker health, and Mneme database health (the last fed by `postgres_exporter`).

F003 also lands two structural changes that benefit the whole stack: the Grafana dashboards directory gains subfolders (`stack/`, `synology/`, `mneme/`) with the file-provisioner running `foldersFromFilesStructure: true`, and the per-service memory budget rebalances within the 600 MB constitutional cap to fund a sixth service. The cross-repo sync mechanism that v1.0 / v1.1 described — and that an earlier reading of F003 would have built — is gone; v1.2 deleted its rationale, and F003 ships zero CI infrastructure for cross-repo dashboard cloning. The nightly Grafana-image-rebuild schedule deferred from F001 likewise does not ship.

---

## User Scenarios & Testing

### Primary User Story

As Stellar, I want to open Grafana and see Mneme's request rates, latencies, ingestion-worker health, and Postgres performance alongside the NAS hardware metrics from F002, so that when something feels slow in Mneme's UI I can tell whether the bottleneck is the application, the database, or the NAS itself — without bouncing between tools or running ad-hoc queries.

### Acceptance Scenarios

**Scenario 1: F003 first deploy succeeds**

**Given** F002's stack is running (5 containers, 4 dashboards) and Mneme is deployed at `main` HEAD ≥ `673d42e` so its `/metrics` endpoints are live
**When** the operator updates the compose file (postgres_exporter added, memory limits rebalanced) and redeploys via Portainer
**Then** a sixth container (`postgres-exporter`) enters the `running` state
**And** all five existing F001/F002 containers remain `Up` with no restarts caused by the rebalance
**And** the new total `mem_limit` sum is exactly 600M (Constitutional cap unchanged)
**And** observed memory across all six services stays well below the cap

**Scenario 2: Postgres metrics user provisioning completes once per NAS**

**Given** Mneme's Postgres is running on `localhost:5433` (per Mneme's compose) but no metrics user exists yet
**When** the operator follows `docs/mneme-setup.md` §Postgres metrics user — runs the documented one-time `docker exec mneme-postgres-1 psql ...` to create a `mneme_metrics` user with `pg_monitor` role and a generated password
**Then** the password is stored in nas-observability's `.env` (Portainer stack environment variables) as `POSTGRES_METRICS_PASSWORD`
**And** `psql` connecting as `mneme_metrics` to Mneme's Postgres returns `pg_stat_database` rows successfully
**And** the user has no permissions beyond `pg_monitor` (no SELECT on user tables, no DDL)

**Scenario 3: All three Mneme scrape jobs report UP**

**Given** the expanded stack is running and Postgres metrics user exists
**When** the operator visits `http://<nas-ip>:9090/targets`
**Then** three Mneme-specific scrape jobs appear alongside the existing four: `mneme-api` (`localhost:3000`), `mneme-worker` (`localhost:3001`), `mneme-postgres` (`localhost:9187` via postgres_exporter)
**And** all three report state `UP` with last-scrape timestamps within their configured intervals
**And** the api and worker job durations are below 1 second; the postgres job below 2 seconds

**Scenario 4: `honor_labels: true` preserves Mneme's self-identification**

**Given** Mneme bakes `instance="<host>:<port>"` and `service="mneme"` into every metric line via its baseline-label injection (per F008 verified output: `db_up{service="mneme",job="mneme-api",instance="DS224plus:3000"} 1`)
**When** Prometheus scrapes `mneme-api` and `mneme-worker` jobs (configured with `honor_labels: true`)
**Then** queries against the resulting time series in Prometheus / Grafana show `instance="DS224plus:3000"` (Mneme's baked value), NOT `instance="localhost:3000"` (the scrape target)
**And** the `service="mneme"` label is preserved on every series
**And** the `mneme-postgres` job (postgres_exporter, generic; does NOT use `honor_labels: true`) shows `instance="localhost:9187"` from the scrape target — the discrimination between consumer-app and adjacent-exporter behaves correctly

**Scenario 5: Mneme API dashboard renders with real data**

**Given** Mneme's api service has been scraped for at least two cycles
**When** the operator opens **Mneme — API** in Grafana (under the `mneme` folder)
**Then** request rate (req/s), latency p50/p95/p99, error rate (4xx and 5xx separately), and DB pool utilization panels render with non-zero data
**And** `db_up` shows `1` (or `0` colored red if the DB connectivity loop is unhealthy)
**And** Node.js process metrics (heap, RSS, event-loop lag) populate from the default `prom-client` collectors
**And** the dashboard is reachable at the URL embedded in its `uid` (`/d/mneme-api/...`)

**Scenario 6: Mneme worker dashboard renders with real data**

**Given** Mneme's worker is running (heartbeat being emitted every N seconds)
**When** the operator opens **Mneme — Worker**
**Then** heartbeat-freshness panel shows the seconds-since-last-heartbeat (computed as `time() - worker_heartbeat_timestamp_seconds`) — green if under threshold
**And** ingestion job counts by state populate (succeeded / failed / low_confidence — the three pre-registered states)
**And** ingestion duration p50/p95/p99 by parser_type renders (may show "no data" cleanly if no ingestions have run yet — pre-registered metrics return zero, not absent)
**And** parser_confidence histograms render

**Scenario 7: Mneme database dashboard renders with real data from postgres_exporter**

**Given** postgres_exporter is connected to Mneme's Postgres and has been scraped for at least two cycles
**When** the operator opens **Mneme — Database**
**Then** active connections, connection-pool saturation, transaction rate (commits + rollbacks), cache hit ratio, and database size panels render with non-zero data
**And** if `pg_stat_statements` extension is not installed in Mneme's Postgres, slow-query panels show "no data" cleanly with an inline note rather than erroring

**Scenario 8: F002 dashboards still render in their new subfolder locations**

**Given** F003 migrates F001/F002's four dashboards (stack-health, nas-overview, storage-volumes, network-temperature) into `stack/` and `synology/` subfolders
**When** the operator opens any of those dashboards
**Then** they render identically to pre-F003 (panels, queries, layout unchanged — only the on-disk path moved)
**And** Grafana's Dashboards browser shows three folders (`mneme`, `stack`, `synology`) with the appropriate dashboards inside each
**And** tag-based filtering still works (`?tag=synology` returns the three NAS dashboards as before)

**Scenario 9: Memory budget respected after rebalance**

**Given** F003 trims cAdvisor (90M → 60M) and node_exporter (50M → 30M) to fund postgres_exporter (50M)
**When** the operator runs `docker stats --no-stream` after the stack has been running ≥ 30 minutes
**Then** every service's observed memory is ≤ its new declared `mem_limit`
**And** the sum of declared `mem_limit` across all six services is exactly 600M
**And** cAdvisor's observed memory (was ~30M / 90M = 67% headroom) now sits in its 60M cap (still ≥ 50% headroom expected)

**Scenario 10: Strip script normalizes Grafana JSON exports**

**Given** an operator authoring a Mneme dashboard locally exports it from Grafana's "Save dashboard → JSON Model" UI
**When** they pipe the exported JSON through `scripts/strip-grafana-export-noise.sh path/to/dashboard.json`
**Then** the four export-environment keys (`__inputs`, `__elements`, `__requires`, `iteration`) are removed
**And** committed dashboard diffs across re-exports stay limited to real content changes (panels, queries, layout) — no environment-noise churn

**Scenario 11: Pre-merge cross-repo verification gate**

**Given** F003's PR is otherwise ready to merge
**When** the reviewer runs through the merge gate
**Then** Mneme's `docs/observability.md` (T013 in Mneme's F008) has been verified to exist on Mneme's `main` branch
**And** the dashboard-ownership language in Mneme's `docs/observability.md` matches v1.2's "Per-application dashboards" Platform Constraint (consumers own `/metrics`; this repo owns visualization)
**And** if the verification fails (T013 not landed, or its language drifted), the F003 PR is held until cross-coordination resolves the inconsistency

### Edge Cases

- **Mneme not deployed when F003 deploys.** scrape jobs report DOWN. The synology/cadvisor/node_exporter scrapes still work. Dashboards show "no data" cleanly. Recovery: deploy Mneme; scrapes recover automatically on next cycle. F003 is robust to Mneme being temporarily off.
- **Mneme's Postgres not exposing 5433.** Pre-spec verification confirmed Mneme's compose binds Postgres to host port 5433 (5432 reserved for DSM's own Postgres). If a future Mneme change closes that port (e.g., Mneme switches to bridge networking), F003's `mneme-postgres` scrape job breaks. Documented in `docs/setup.md` troubleshooting: how to verify Mneme's Postgres host-port exposure.
- **Postgres metrics user missing or wrong password.** postgres_exporter logs an authentication error; the scrape job reports DOWN. Recovery: re-run the SQL from `docs/mneme-setup.md` §Postgres metrics user, update `.env` if the password rotated.
- **Mneme not running `prom-client`'s default Node.js collectors.** Some default metrics (heap, RSS, event-loop lag) won't be present. Dashboards render those panels as "no data." Mneme F008's instrumentation backbone enables the default collectors per its T002, so this should not occur in practice.
- **`honor_labels: true` accidentally applied to `mneme-postgres`.** postgres_exporter doesn't bake `instance` into its output, so `honor_labels: true` on that job would leave the `instance` label empty. PR-time check: `mneme-postgres` does NOT have `honor_labels: true`. Compliance gate.
- **Subfolder migration reveals a dashboard with a hardcoded URL referencing the old flat path.** Unlikely (dashboards are loaded by `uid`, not path) but possible if anyone bookmarked a flat URL. Documented as a one-line note in `docs/deploy.md`: "F003 dashboards moved from flat to subfolders; bookmarks based on `uid` are unchanged, but if you bookmarked the directory listing it'll need updating."
- **`pg_monitor` role missing on older Postgres.** `pg_monitor` was introduced in Postgres 10. Mneme runs `pgvector/pgvector:pg16` per its compose, well above the requirement. If a future Mneme PR downgrades Postgres, F003's metrics user provisioning command breaks until the role exists or alternative privileges are granted.
- **Mneme's worker heartbeat thread crashes silently.** `worker_heartbeat_timestamp_seconds` stops updating; `time() - worker_heartbeat_timestamp_seconds` climbs. The worker dashboard surfaces this immediately. The future MnemeWorkerDown alert (Mneme T010 + nas-observability alerting feature) gates on this same signal.
- **postgres_exporter version's metric names diverge from dashboard expectations.** postgres_exporter has shipped occasional renames across versions. Plan-time check: verify the metric names referenced in dashboard PromQL match the pinned exporter version's output. Same anti-pattern defense as F002's D4 traceability table.

---

## Requirements

### Functional Requirements

- **FR-29:** The system MUST add a sixth service `postgres-exporter` to `docker-compose.yml` using the upstream `prometheuscommunity/postgres-exporter` image at a pinned version (verified at plan time), with `network_mode: host`, `restart: unless-stopped`, and an explicit `mem_limit`. [Constitution: Principles I, III, IV]
- **FR-30:** The `postgres-exporter` service MUST connect to Mneme's Postgres at `localhost:5433` using a `mneme_metrics` user provisioned with the `pg_monitor` role. The connection password lives in `.env` (or Portainer stack environment variables) as `POSTGRES_METRICS_PASSWORD`. [Constitution: Principles I, II]
- **FR-31:** The system MUST ship `docs/mneme-setup.md` documenting the one-time DSM-side runbook for provisioning the `mneme_metrics` user via `docker exec mneme-postgres-1 psql ...` (Decision D1). The provisioning SQL MUST be idempotent / safely re-runnable — either via a `DO $$ ... IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mneme_metrics') THEN CREATE USER ... END IF; END $$;` block, OR the runbook MUST explicitly document `ERROR: role "mneme_metrics" already exists` as the expected signal on a re-run (so an operator who runs the command twice doesn't fear they corrupted state). Plan picks the mechanism. [Constitution: Principle II §carved-out manual-step exception]
- **FR-32:** The system MUST add three new scrape jobs to `config/prometheus/prometheus.yml`: `mneme-api` (target `localhost:3000`), `mneme-worker` (target `localhost:3001`), `mneme-postgres` (target `localhost:9187`). Existing F001/F002 scrape jobs MUST be unchanged. [Constitution: Principle III]
- **FR-33:** The `mneme-api` and `mneme-worker` scrape jobs MUST set `honor_labels: true`. Mneme bakes `instance="<host>:<port>"` and `service="mneme"` into every metric line at exposition time; without `honor_labels: true`, Prometheus would overwrite Mneme's self-identified `instance` with the scrape target's `__address__`. The `mneme-postgres` job MUST NOT set `honor_labels: true` — postgres_exporter is a generic exporter that does not bake `instance`, and Prometheus's default behavior of populating `instance` from the scrape target is correct there. [Constitution: Principle II; this is a spec-level requirement, not a plan detail]
- **FR-34:** The system MUST bake three Mneme dashboards into the custom Grafana image at `/etc/grafana/dashboards/mneme/`: `api.json`, `worker.json`, `database.json`. Each dashboard MUST declare tags `[mneme, api]`, `[mneme, worker]`, `[mneme, database]` per the constitution's Tier 1 / Tier 2 tag convention. [Constitution v1.2: Platform Constraints §Per-application dashboards]
- **FR-35:** The Grafana dashboard provisioning provider MUST set `foldersFromFilesStructure: true` so that each subdirectory under `/etc/grafana/dashboards/` becomes a Grafana folder. Verified empirically working on Grafana 11.4 during pre-spec investigation. [Constitution v1.2]
- **FR-36:** F001 and F002 dashboards (`stack-health.json`, `nas-overview.json`, `storage-volumes.json`, `network-temperature.json`) MUST be moved into the `stack/` and `synology/` subfolders respectively. Layout post-F003: `dashboards/stack/stack-health.json`, `dashboards/synology/nas-overview.json`, `dashboards/synology/storage-volumes.json`, `dashboards/synology/network-temperature.json`, plus the three new `mneme/` entries. The migration is atomic in F003's single PR — no backwards-compat dual layout. [Constitution v1.2]
- **FR-37:** Each Mneme dashboard MUST reference the Prometheus datasource by explicit UID (`datasource.uid: "prometheus"`). [Constitution v1.1: Platform Constraints §Grafana datasource UIDs must be explicit]
- **FR-38:** Each Mneme dashboard MUST set `editable: false`. Authoring follows the established workflow (local Grafana with `editable: true`, iterate, export, run through the strip script, commit with `editable: false`). [Constitution: Principle II]
- **FR-39:** The system MUST commit `scripts/strip-grafana-export-noise.sh` — a port of Mneme's same-named script. Removes the four export-environment keys (`__inputs`, `__elements`, `__requires`, `iteration`) that Grafana injects on every JSON export, keeping committed diffs limited to real content changes. Committed executable (mode 100755). [Constitution: Principle II — repo as source of truth for ergonomic tooling]
- **FR-40:** The system MUST update `docs/ports.md` moving `9187` (postgres_exporter) from "Reserved for later features" to "Current assignments" with F003 as the claiming feature. [Constitution: Principle III]
- **FR-41:** Memory budget rebalance per Decision D5: cAdvisor `mem_limit` reduced from 90M → 60M, node_exporter from 50M → 30M, postgres_exporter allocated 50M. New per-service `mem_limit` sum: 280 + 140 + 60 + 30 + 40 + 50 = exactly **600M**. F002's snmp_exporter at 40M is unchanged; Prometheus and Grafana unchanged. [Constitution: Principle IV]
- **FR-42:** The `postgres-exporter` service runs as the image-default user (no `user:` override). Postgres exporter is stateless (no bind mounts), so v1.1's DSM UID restriction does not apply — the constraint is about writes to `/volume1/`, and postgres_exporter doesn't write anywhere on the NAS filesystem. Differs from Prometheus and Grafana, which DO need `user: "1026:100"` because they write bind-mounted state. [Constitution v1.1: Platform Constraints §DSM UID restriction]
- **FR-43:** The cross-repo dependency on Mneme F008 T013 (`docs/observability.md`) MUST be verified before F003's PR merges. Verification: (a) Mneme's `docs/observability.md` exists on Mneme's `main` branch; (b) its dashboard-ownership language matches v1.2's "Per-application dashboards" Platform Constraint (consumers own `/metrics` contract; this repo owns visualization). If either check fails, F003 is held until cross-coordination resolves the inconsistency. [Constitution v1.2 + Governance]
- **FR-44:** Every PR that adds or modifies a service in this feature MUST satisfy the constitutional compliance checklist (pinned version, `mem_limit`, total ≤ 600M, port declared in `docs/ports.md`, bind mount documented if stateful). The `mneme-postgres` job's missing-`honor_labels` discipline is also a PR-time check. [Constitution: Governance]

### Non-Functional Requirements

- **NFR-13:** Total stack memory allocation MUST sum to exactly 600M after F003's rebalance. Observed memory across six services SHOULD remain below 70% of the cap. F002's actual baseline was ~40% utilization (224 MiB / 560 MiB allocated); F003's six-service stack should land around 45–55% if patterns hold. 70% is a soft warning threshold — if observed memory climbs past it, investigate before raising any `mem_limit`. [Constitution: Principle IV]
- **NFR-14:** Each Mneme dashboard MUST render within 3 seconds on first view after at least two scrape cycles. Matches F002's NFR-8 baseline.
- **NFR-15:** The `mneme-api` and `mneme-worker` scrape job durations MUST stay below 1 second under normal Mneme load. The `mneme-postgres` scrape duration MUST stay below 2 seconds. (Mneme's `/metrics` endpoints are lightweight Node.js exports; postgres_exporter's queries against `pg_stat_*` views are fast at single-instance scale.)
- **NFR-16:** postgres_exporter's observed memory SHOULD remain below 50M (its declared `mem_limit`). At single-instance Postgres scrape scale, typical footprint is 20-40M; the 50M allocation is generous. If observed usage approaches 50M, investigate (e.g., `pg_stat_statements` cardinality if enabled) before raising the limit.
- **NFR-17:** Grafana subfolder rendering (3 folders post-F003) MUST be verified to behave correctly via `/api/folders` endpoint after image deploy. Empirically verified during pre-spec investigation that Grafana 11.4's `foldersFromFilesStructure: true` works as expected; deploy-time check confirms this on the production image.

### Key Entities

- **postgres_exporter** (`prometheuscommunity/postgres-exporter`): the upstream container that scrapes Postgres `pg_stat_*` views and translates them into Prometheus metrics format. Stateless (no bind mounts). Bound to port 9187 on the NAS host. Connects to Mneme's Postgres via DSN sourced from `.env` (`POSTGRES_METRICS_PASSWORD`).
- **`mneme_metrics` Postgres user**: a read-only user on Mneme's Postgres provisioned via the one-time SQL command in `docs/mneme-setup.md`. Has the `pg_monitor` role; nothing more. NOT the same user as Mneme's app `POSTGRES_USER`.
- **Mneme dashboards**: three Grafana JSON files at `docker/grafana/dashboards/mneme/` — `api.json`, `worker.json`, `database.json`. Baked into the custom Grafana image at `/etc/grafana/dashboards/mneme/` per v1.2 Platform Constraints. Authored against Mneme's `/metrics` contract documented in Mneme's `docs/observability.md` (T013, pending in Mneme).
- **Subfolder dashboard layout**: `docker/grafana/dashboards/{stack,synology,mneme}/` after F003. F002's flat layout migrated atomically in F003's PR. Provisioner runs `foldersFromFilesStructure: true`.
- **Strip script**: `scripts/strip-grafana-export-noise.sh`. Single `jq` invocation that removes `__inputs`, `__elements`, `__requires`, and `iteration` keys from a Grafana JSON export.
- **`docs/mneme-setup.md`**: NAS-side runbook for the one-time `mneme_metrics` user provisioning. Sister doc to `docs/snmp-setup.md` from F002.

---

## Specific Decisions (resolved in this spec)

### D1. Postgres metrics user — provisioned via one-time operator SQL command

Mneme owns its Postgres but F003 needs a read-only metrics user. Three plausible mechanisms:

- (a) Use Mneme's existing app user (`POSTGRES_USER`). Has full app privileges; over-privileged for scraping; no.
- (b) Mneme provisions `mneme_metrics` via a Drizzle migration in Mneme's repo. Cleanest from a "Mneme owns its Postgres" perspective, but requires a Mneme PR before F003 can proceed.
- (c) F003 documents a one-time `docker exec mneme-postgres-1 psql -c 'CREATE USER ...; GRANT pg_monitor TO ...'` command the operator runs once via SSH. NAS-side action mirroring F002's `.community` pattern; no Mneme code change.

**Spec picks (c).** Reasoning: F003 has explicit "no Mneme code changes required" as a design constraint (otherwise F003 blocks on a Mneme PR cycle for what is fundamentally an observability-side concern). The Mneme team can adopt (b) as a future Mneme PR if they want — that's a Mneme decision, and it would not break F003's setup (Mneme's migration would CREATE OR REPLACE the user; password coordination handled via the same `.env` variable).

### D2. Postgres credentials — `.env` based

The `mneme_metrics` user's password lives in nas-observability's `.env` (Portainer stack environment variables) as `POSTGRES_METRICS_PASSWORD`. Operator generates the password during the one-time SQL command in setup, copies into Portainer's stack env field. postgres_exporter reads it at startup via standard env-var DSN composition.

Differs from F002's `.community` approach (NAS-side secret file outside `.env`) because:
- The community string was a Synology system credential we wanted treated specially (file mode 600, single-source-of-truth).
- The Postgres metrics password is a credential we generate and own; `.env` is the established pattern for credentials nas-observability owns (alongside `GRAFANA_ADMIN_PASSWORD`).
- postgres_exporter reads env vars natively; no rendering step needed (no equivalent to the snmp.yml.template + sed flow).

### D3. Subfolder migration — atomic in F003 PR

F003 moves F001/F002's four flat dashboards into `stack/` and `synology/` subfolders in the same PR. No backwards-compat dual layout, no provisioning flag for "old or new path." Single cutover.

Reasoning: backwards-compat would mean shipping the dashboards in two locations during a transition period, then removing one in a future PR — added complexity for a single-operator homelab. Atomic cutover is one PR, one image rebuild, one redeploy. Dashboard `uid` values are unchanged, so any `/d/<uid>/` URL bookmarks survive the move.

### D4. postgres_exporter image version — pinned at plan time

Image: `quay.io/prometheuscommunity/postgres-exporter:v0.16.0` (or latest stable verified at plan-time via `docker manifest inspect`, per F001's lesson that upstream tag assumptions occasionally lie). The plan resolves the exact version pin and includes the manifest verification.

### D5. Memory budget rebalance — donor-trim pattern

Pre-F003 (F002 baseline):

| Service       | `mem_limit` |
|---------------|-------------|
| Prometheus    | 280M        |
| Grafana       | 140M        |
| cAdvisor      | 90M         |
| node_exporter | 50M         |
| snmp_exporter | 40M         |
| **Total**     | **600M**    |

Post-F003:

| Service        | `mem_limit` | Change | Observed (F002 close) | New headroom |
|----------------|-------------|--------|------------------------|--------------|
| Prometheus     | 280M        | unchanged | ~102M | 64% |
| Grafana        | 140M        | unchanged | ~85M  | 39% |
| cAdvisor       | **60M**     | **−30M** | ~30M  | **50%** (was 67%) |
| node_exporter  | **30M**     | **−20M** | ~7M   | **77%** (was 86%) |
| snmp_exporter  | 40M         | unchanged | ~30M  | 25% |
| **postgres_exporter** | **50M** | **+50M (new)** | TBD | TBD |
| **Total**      | **600M**    |        |                        |              |

cAdvisor and node_exporter are donor-trimmed because they had the largest observed-vs-cap headroom in F002. cAdvisor's 67% headroom drops to 50% — comfortable but no longer huge. node_exporter's 86% drops to 77% — still huge.

**Forward-looking note (carries to F004+):** future exporter additions should trim from grafana (39% headroom) or node_exporter (77%) before cAdvisor (now at 50%). The order of donation reflects the order of remaining headroom; cAdvisor was disproportionately favored in F001's allocation and has been correcting since.

### D6. F003 PR shape — single PR by default

F003 ships as a single integrated PR by default: postgres_exporter wiring, three Mneme dashboards, subfolder migration, strip script port, docs updates. If during implementation the diff grows beyond ~1500 lines or review feels unwieldy, splitting at a natural boundary (infrastructure/wiring vs. dashboards) is acceptable — a judgment call at implementation time, not a pre-commitment.

### D7. Cross-repo dependency on Mneme F008 T013

F003's spec **references** Mneme's `docs/observability.md` (T013, pending in Mneme) as the integration-contract source. F003's plan and tasks include a pre-implementation verification that T013 has actually landed and matches v1.2's dashboard-ownership language. The verification is explicit (FR-43): the F003 PR is held until both checks pass.

If T013 lands with content that diverges from v1.2 (e.g., still asserts dashboards live in Mneme), the discrepancy is resolved before F003 merges — either Mneme amends T013 to align with v1.2, or v1.2 itself needs revisiting. The bias is: v1.2 won the architecture conversation; Mneme's T013 reflects v1.2.

### D8. Worker dashboard split — deferred decision

F003 ships a single `mneme/worker.json` covering heartbeat, ingestion job state, ingestion duration, parser confidence, and Node.js process metrics. If the dashboard becomes too dense in practice (eyeball thresholds: more than ~10–12 panels, or two logically distinct concerns where ingestion-specific metrics dominate the worker-fundamentals signal), split into:

- `mneme/worker.json` — heartbeat freshness, Node.js process metrics, worker-internal health
- `mneme/ingestion.json` — ingestion job state by parser, duration histograms, parser confidence

**Defer pending observation of dashboard density.** F003 ships the consolidated version; the split is a follow-up PR if needed. Tags would shift accordingly: existing `[mneme, worker]` stays on `worker.json`; new `[mneme, ingestion]` for `ingestion.json`. The Tier 2 `ingestion` value is reserved here so future features don't claim it for something else.

---

## Success Criteria

This feature is complete when:

1. A redeploy in Portainer brings up six containers; total declared `mem_limit` sums to exactly 600M.
2. `http://<nas-ip>:9090/targets` shows all seven scrape jobs UP: prometheus, cadvisor, node_exporter, synology, mneme-api, mneme-worker, mneme-postgres.
3. Querying any Mneme metric in Prometheus returns series with `instance="DS224plus:3000"` (or `:3001`) — Mneme's self-identified value preserved by `honor_labels: true`. The `mneme-postgres` series have `instance="localhost:9187"` from the scrape target (no `honor_labels`).
4. All seven dashboards render within 3 seconds: stack-health (in `stack/` folder), three NAS dashboards (in `synology/`), three Mneme dashboards (in `mneme/`).
5. Grafana's Dashboards browser shows three folders, dashboards correctly assigned per `foldersFromFilesStructure: true`.
6. `docker stats --no-stream` confirms each service within its new `mem_limit`; total observed ≤ 60% of the 600M cap.
7. The `docs/mneme-setup.md` runbook produces a working `mneme_metrics` user on a fresh provision.
8. Strip script removes the four export-environment keys when piped a Grafana JSON export.
9. Mneme's `docs/observability.md` (T013) has landed and been cross-read; FR-43's verification passed.

Explicitly not required for this feature:

- Alertmanager, alert rules from Mneme (or anywhere), email delivery — deferred to dedicated alerting feature.
- Other consumer apps (Pinchflat, Immich, Home Assistant) — own future features.
- Multi-arch Grafana image — F002 carry-over, still deferred (per F002 retro carry-over criteria).
- Walkgen replacement of `snmp.yml.template` — F002 carry-over, still deferred (per F002 retro carry-over criteria).
- Reverse proxy / external access — separate feature.

---

## Out of Scope

- **Alert rules, Alertmanager, SMTP** — F003 ships dashboards, not alerts. Mneme's `mneme.rules.yml` (when its T010 ships) and the rule-loading infrastructure here are the dedicated alerting feature's scope.
- **Cross-repo dashboard sync** — explicitly deleted by Constitution v1.2. F003 ships zero CI infrastructure for cloning Mneme's repo, copying `ops/dashboards/`, or any related plumbing. The directory `docker/grafana/dashboards/mneme/` is authored directly here.
- **Nightly Grafana-image-rebuild schedule** — deferred from F001 with the understanding it would ship in F003. v1.2 deleted its rationale (no external dashboard source to poll). F003 does NOT add a `schedule:` trigger to `.github/workflows/build-grafana-image.yml`.
- **Mneme application-side changes** — Mneme F008 T010-T016 (alert rules, instrumentation tests, integration docs) are Mneme's parallel work stream. F003 depends only on T001-T009 (already deployed) plus T013 (cross-repo gate per FR-43).
- **postgres_exporter for DSM's internal Postgres** — out of scope. DSM's Postgres is locked-down system infrastructure; not a meaningful application target.
- **`pg_stat_statements` extension setup** — if Mneme enables it on their Postgres, the database dashboard's slow-query panels populate; if not, those panels show "no data" cleanly. F003 does not require the extension.
- **Future consumer apps** (Pinchflat, Immich, Home Assistant, etc.) — F004+ each. F003 establishes the per-application pattern but ships only Mneme.
- **Multi-arch Grafana image** (carry-over from F002 retro). Still deferred; revisit when native arm64 GHA runners are GA.
- **Walkgen replacement of `snmp.yml.template`** (carry-over from F002 retro). Still deferred per its trigger criteria.

---

## Notes for `/plan` and `/tasks`

When this feature is started, `plan.md` resolves the following (explicitly deferred from this spec):

- **postgres_exporter exact image version pin.** Verify the tag exists at plan time via `docker manifest inspect quay.io/prometheuscommunity/postgres-exporter:<tag>`. F001's lesson on `grafana/grafana:11.4.0-oss` not existing applies.
- **Exact Postgres connection DSN format.** `DATA_SOURCE_NAME=postgresql://mneme_metrics:${POSTGRES_METRICS_PASSWORD}@localhost:5433/<db>?sslmode=disable` — confirm the database name (Mneme's `POSTGRES_DB`) and that `sslmode=disable` is correct for localhost (no TLS).
- **Exact panels per Mneme dashboard.** Spec commits to the three dashboards and the categorical metric coverage; plan designs individual panels and PromQL. **Build a traceability table** mirroring F002's D4 — every Mneme dashboard panel cites a metric from Mneme's `/metrics` contract (or postgres_exporter's published metric list). Sources: Mneme's F008 spec for api/worker metric names; postgres_exporter's release notes for the database metrics.
- **Exact `docs/mneme-setup.md` step-by-step.** Spec commits to the runbook's purpose; plan drafts the SQL command, password generation guidance (`openssl rand -base64 24` or similar), Portainer env-var update steps, and verification (`psql` connectivity test).
- **Subfolder migration mechanics.** Plan resolves whether the migration is done as a single `git mv` chunk or rebuilt from scratch (probably `git mv` to preserve diff history).
- **Pre-implementation cross-repo verification (FR-43).** Plan adds a Phase 0 task: "Verify Mneme's `docs/observability.md` has landed on Mneme's `main` branch and its dashboard-ownership language matches v1.2." Resolution path if not yet landed: pause F003, ping Mneme work-stream, resume when T013 ships. Tasks.md memorializes this as the Phase 0 gate.
- **Deferred Mneme metric verification.** Plan/tasks include a smoke-test task: `curl -s http://localhost:3000/metrics | grep -E '^http_requests_total|^db_up|^http_request_duration'` etc. on the deployed Mneme to verify metric names match what dashboards reference. Anti-pattern defense for "panel queries metric that doesn't exist."
- **Provisioner config update for `foldersFromFilesStructure: true`.** Plan resolves the exact YAML diff to `docker/grafana/provisioning/dashboards/dashboards.yaml`.

`tasks.md` will decompose into phases mirroring F002's pattern but adjusted for F003's scope: (1) Phase 0 pre-merge gates (cross-repo T013 verification, Mneme `/metrics` smoke-test), (2) Postgres metrics user runbook + execution, (3) Compose + scrape-config wiring, (4) D4-equivalent dashboard traceability table, (5) Three Mneme dashboards authored + strip-script use, (6) Subfolder migration of F002 dashboards, (7) DS224+ deploy + acceptance walk-through, (8) Stability observation over **24 hours** matching F002's discipline. The longer window is justified because F003 introduces net-new behavior (postgres_exporter scraping Mneme's Postgres in production) that hasn't been characterized, and diurnal patterns (Hyper Backup, scheduled jobs, day/night usage variance for a PKM tool) need a full 24h window to surface.

**Plan-resolved mechanism: "no data with inline note" panels** (Scenario 7's slow-query panels when `pg_stat_statements` isn't installed). Grafana doesn't natively support inline-note text on no-data panels. Plan picks between: (a) adjacent text panel in the same row as the affected query panel; (b) panel-level `description` text rendered in the info-icon tooltip; (c) panel `noValue` config showing a custom string instead of "no data". Recommendation TBD at plan time.

`scripts/strip-grafana-export-noise.sh` is a small T001-class task (port file, chmod +x, document usage in a README or in `docs/deploy.md`).
