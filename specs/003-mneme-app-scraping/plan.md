# Implementation Plan: Mneme Application Scraping & Dashboards

**Feature Branch:** `003-mneme-app-scraping`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-04-26

---

## Technical Context

F003 is the first feature implemented under Constitution v1.2's "Per-application dashboards" Platform Constraint (Architecture B): consumer dashboards live in this repository under `docker/grafana/dashboards/<consumer-slug>/`, baked at image-build time. Mneme is the first consumer; F004+ consumers (Pinchflat, Immich, etc.) follow the same pattern.

The technical scope is small in component count — one new service (postgres_exporter), three new scrape jobs, three new dashboards, one provisioner-config change, one strip-script port, one runbook. The substantive work is in the *contract surfaces*: the cross-repo dependency on Mneme F008 T013, the metric-traceability discipline that prevents shipping panels against OIDs that don't exist (F002's D4 anti-pattern defense ported here), and the subfolder migration that touches every dashboard path the Dockerfile already references.

**Runtime & images:**
- `quay.io/prometheuscommunity/postgres-exporter:v0.16.0` — upstream, unmodified. Pin verified at implementation time via `docker manifest inspect` (F001 lesson: upstream tag assumptions sometimes lie).
- All F001/F002 images and versions unchanged.
- Custom Grafana image rebuilds with the new dashboards baked in plus the subfolder migration.

**Cross-repo dependencies:**
- **Mneme F008 T001-T009** deployed on the NAS (verified via spec-time curl: `db_up{service="mneme",job="mneme-api",instance="DS224plus:3000"} 1`).
- **Mneme F008 T013** (`docs/observability.md`) pending in Mneme's parallel work stream. F003 PR cannot merge until T013 has landed and cross-read against v1.2's "Per-application dashboards" Platform Constraint. Phase 0 of this plan enforces the gate.

**Networking:** `network_mode: host` throughout (Principle III). postgres_exporter on port 9187 (already reserved in `docs/ports.md` from F001).

**User:** postgres_exporter runs as image-default user — stateless, no bind mounts, v1.1's DSM UID restriction does not apply (constraint is about writes to `/volume1/`, postgres_exporter doesn't write anywhere). Differs from Prometheus and Grafana, which DO need `user: "1026:100"` because they persist state.

**Bind mounts:** none new. postgres_exporter has no persistent state; its only "config" is the connection DSN passed via env.

---

## Constitution Check

Measured against [`constitution.md`](../../.specify/memory/constitution.md) v1.2.0.

| Constraint | Status | Notes |
|---|---|---|
| I. Upstream-First, Thin Customization | ✅ Pass | `prometheuscommunity/postgres-exporter` unmodified at pinned version. No fork. Custom image stays Grafana-only. |
| II. Declarative Configuration | ✅ Pass | All scrape config, compose, dashboards, and provisioner config committed. The one-time `mneme_metrics` user SQL provisioning is the documented manual step (mirrors F002's `synoacltool -del` and SNMP-enable pattern; carved out of Principle II). |
| III. Host Networking by Default | ✅ Pass | `network_mode: host` on postgres_exporter. Port 9187 moved from "Reserved" to "Current" in `docs/ports.md`. Scrape target `localhost:9187`. |
| IV. Resource Discipline | ✅ Pass | Total stack `mem_limit` sum stays at exactly 600M after donor-trim (cAdvisor 90→60M, node_exporter 50→30M, postgres_exporter +50M). 30-day Prometheus retention unchanged. |
| V. Silent-by-Default Alerting | N/A | No alerts shipped in F003. |
| v1.1 §DSM UID restriction | ✅ Pass (by exemption) | postgres_exporter has no `/volume1/` writes; runs as image-default user (FR-42). Constraint applies to consumers writing bind mounts; postgres_exporter doesn't qualify. |
| v1.1 §Separate baked config from persisted state | ✅ Pass | Three new dashboards bake into `/etc/grafana/dashboards/mneme/` (config). `/var/lib/grafana/` continues as state-only. |
| v1.1 §Grafana datasource UIDs must be explicit | ✅ Pass | All three Mneme dashboards reference `datasource.uid: "prometheus"`. |
| v1.2 §Per-application dashboards | ✅ Pass — first implementation | Dashboards live in this repo at `docker/grafana/dashboards/mneme/`, baked at build time. No cross-repo sync. Provisioner uses `foldersFromFilesStructure: true`. Mneme's `docs/observability.md` (T013, pending) is the integration-contract reference. |

**Violations:** none.

---

## Project Structure

### Files introduced by this feature

```
nas-observability/
├── config/
│   └── prometheus/
│       └── prometheus.yml             # MODIFIED — three new scrape jobs
│
├── docker/
│   └── grafana/
│       ├── Dockerfile                 # MODIFIED — inject-build-metadata path update
│       ├── provisioning/
│       │   └── dashboards/
│       │       └── dashboards.yaml    # MODIFIED — foldersFromFilesStructure: true
│       └── dashboards/
│           ├── stack/                 # NEW DIR (subfolder migration)
│           │   └── stack-health.json  # MOVED from flat layout
│           ├── synology/              # NEW DIR
│           │   ├── nas-overview.json          # MOVED
│           │   ├── storage-volumes.json       # MOVED
│           │   └── network-temperature.json   # MOVED
│           └── mneme/                 # NEW DIR
│               ├── api.json           # NEW
│               ├── worker.json        # NEW
│               └── database.json      # NEW
│
├── scripts/
│   └── strip-grafana-export-noise.sh  # NEW — port from Mneme repo
│
├── docs/
│   └── mneme-setup.md                 # NEW — postgres metrics user runbook
│
└── (also modified: docker-compose.yml, docs/ports.md, docs/setup.md,
   docs/deploy.md, .env.example, README.md)
```

### Migration via `git mv` (preserves diff history)

```bash
mkdir -p docker/grafana/dashboards/{stack,synology,mneme}
git mv docker/grafana/dashboards/stack-health.json docker/grafana/dashboards/stack/
git mv docker/grafana/dashboards/nas-overview.json docker/grafana/dashboards/synology/
git mv docker/grafana/dashboards/storage-volumes.json docker/grafana/dashboards/synology/
git mv docker/grafana/dashboards/network-temperature.json docker/grafana/dashboards/synology/
```

`git mv` preserves rename detection on the diff; `git log --follow <new-path>` traces back through the rename to F001/F002 history. F003's PR review surfaces the moves cleanly as renames rather than delete-add pairs.

### What this feature does NOT introduce

- Cross-repo CI sync (deleted by Constitution v1.2 — see Out of Scope in spec).
- Nightly Grafana-image-rebuild schedule (also v1.2-deleted; F001 deferral resolved by removal, not deferral renewal).
- Alertmanager, alert rule files, or any rule-loading config in Prometheus.
- A custom postgres_exporter image (Principle I — upstream is sufficient).
- Mneme-side code or compose changes (Mneme F008 T001-T009 already provides what F003 needs from Mneme; T013 is doc-only).

---

## Service Configuration: postgres_exporter

### Compose entry

**Image:** `quay.io/prometheuscommunity/postgres-exporter:v0.16.0`
**Host port:** 9187
**Memory limit:** 50M (per Spec D5 — see Memory Budget below)
**User:** image default (no `user:` override; per FR-42)
**Restart policy:** `unless-stopped`

**Environment:**
```yaml
environment:
  - DATA_SOURCE_NAME=postgresql://mneme_metrics:${POSTGRES_METRICS_PASSWORD}@localhost:5433/postgres?sslmode=disable
```

**Why connect to `postgres` system DB rather than Mneme's app DB:** the metrics user with `pg_monitor` role accesses `pg_stat_*` views which are global (visible from any database connection). Connecting to the always-present `postgres` system DB removes the dependency on knowing Mneme's `POSTGRES_DB` value (which lives in Mneme's `.env`, not ours). postgres_exporter's queries operate against catalog views that don't care which DB the session connected to.

**Why `sslmode=disable`:** the connection is loopback (`localhost:5433`) on a single host; TLS is overhead without payoff. If Mneme ever exposes Postgres beyond the host (it doesn't currently), revisit.

**Volumes:** none. postgres_exporter is stateless.

**No Docker healthcheck.** `prometheuscommunity/postgres-exporter` is a distroless-style image — no shell, no `wget`, no `curl`. A healthcheck calling those binaries would fail at container start because the binaries aren't in the image. Operational health signal is `up{job="mneme-postgres"}` from Prometheus's scrape (1 = exporter HTTP responding, 0 = scrape failed) plus `pg_up{}` (1 = exporter's Postgres connection healthy, 0 = exporter is up but DB connection failed). Future alerting feature gates on `up == 0` and `pg_up == 0` separately for those two distinct failure modes; no Docker-level healthcheck adds anything actionable here.

### Memory budget (per Spec D5)

Pre-F003 (F002 baseline at cap):

| Service | `mem_limit` | F002-observed |
|---|---|---|
| Prometheus | 280M | ~102M |
| Grafana | 140M | ~85M |
| cAdvisor | 90M | ~30M |
| node_exporter | 50M | ~7M |
| snmp_exporter | 40M | ~30M |
| **Total** | **600M** | **~254M (42%)** |

Post-F003:

| Service | `mem_limit` | Change | F002 observed | Expected post-F003 | New headroom |
|---|---|---|---|---|---|
| Prometheus | 280M | unchanged | ~102M | ~102M | 64% |
| Grafana | 140M | unchanged | ~85M | ~85M | 39% |
| cAdvisor | **60M** | **−30M** | ~30M | ~30M | 50% (was 67%) |
| node_exporter | **30M** | **−20M** | ~7M | ~7M | 77% (was 86%) |
| snmp_exporter | 40M | unchanged | ~30M | ~30M | 25% |
| **postgres_exporter** | **50M** | **+50M (new)** | n/a | ~20–40M | 20–60% (TBD) |
| **Total** | **600M** | net 0 | ~254M (42%) | ~284M (47%) | |

**Per Spec D5's forward-looking rule (cross-reference for future readers):** post-F003, **cAdvisor is now protected** — its remaining headroom (50%) is narrower than node_exporter's (77%) or grafana's (39%). Future feature additions that need to free memory should trim from grafana or node_exporter before cAdvisor. The order of donation reflects the order of remaining headroom; cAdvisor was disproportionately favored in F001's allocation and has been correcting since. Plan citation here for visibility; spec D5 is the authoritative source.

---

## Prometheus Scrape Jobs

Three jobs added to `config/prometheus/prometheus.yml`. F001/F002 jobs unchanged.

```yaml
  - job_name: mneme-api
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:3000']

  - job_name: mneme-worker
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:3001']

  - job_name: mneme-postgres
    scrape_interval: 30s
    static_configs:
      - targets: ['localhost:9187']
```

**Why `honor_labels: true` on api/worker but NOT postgres** (per FR-33, spec-level):

Mneme's `/metrics` output bakes `instance="DS224plus:3000"`, `job="mneme-api"`, and `service="mneme"` into every line at exposition time. Without `honor_labels: true`, Prometheus overwrites the consumer's `instance` value with the scrape target's `__address__` (`localhost:3000`), destroying Mneme's hostname information. With `honor_labels: true`, Prometheus keeps Mneme's self-identification and uses `__address__` only for connection.

postgres_exporter is a **generic** exporter (not consumer-app code); it doesn't bake `instance` into its output. Prometheus's default behavior (populating `instance` from the scrape target as `localhost:9187`) is correct there. Setting `honor_labels: true` on `mneme-postgres` would leave `instance` empty — wrong outcome.

**Compliance check at PR-time** — automated, not just review discipline. See §`honor_labels` count gate (CI-enforced) below.

**Why 15s for api/worker, 30s for postgres_exporter:** Mneme's `/metrics` endpoints serialize an in-memory metric registry (lightweight, sub-100ms on similar deploys per F008 T007 measurements). postgres_exporter executes actual SQL queries against `pg_stat_*` views on every scrape — heavier, but still well under 1s on single-instance Postgres scale. 30s is conservative; could probably tighten to 15s but cost-of-being-conservative is zero.

### `honor_labels` count gate (CI-enforced)

The consumer-vs-generic-exporter discrimination is load-bearing: getting it wrong silently destroys label information without any deploy-time failure (Prometheus accepts both configurations cleanly). Per FR-44, this is a PR-time compliance check; per the same precedent F001/F002 set for image pinning, `mem_limit` totals, and port table updates, the check is machine-enforced.

A new step lands in `.github/workflows/build-grafana-image.yml` (per scoping decision: bundle into the existing build workflow rather than fragmenting into a separate compliance workflow):

```yaml
- name: Verify honor_labels count in prometheus.yml
  run: |
    actual=$(grep -c '^[[:space:]]*honor_labels: true' config/prometheus/prometheus.yml || true)
    expected=2  # F003: mneme-api + mneme-worker. Update in feature PR when consumers
                # with self-identifying instance labels are added (F004+).
    if [ "$actual" -ne "$expected" ]; then
      echo "::error::honor_labels count mismatch: found $actual, expected $expected." >&2
      echo "::error::See specs/003-mneme-app-scraping/plan.md §honor_labels count gate for the consumer-vs-generic discrimination rule." >&2
      exit 1
    fi
    echo "honor_labels count: $actual (matches expected $expected)"
```

Step lives in the existing `build-and-push` job. The workflow's trigger paths get extended to include `config/prometheus/prometheus.yml` so the check runs on prometheus.yml changes.

**Tradeoff acknowledged:** changes to `prometheus.yml` will now also rebuild the Grafana image (~40s of CI time), even though the image content doesn't depend on prometheus.yml. Cost is small; benefit is single-source-of-truth CI configuration. Alternative (separate `compliance-checks.yml` workflow file) would scope triggers more precisely but fragments the CI surface.

When F004+ adds a new consumer-app scrape job that bakes its own `instance` label, the feature PR updates `expected` in this step. The check is forward-extensible without restructure.

---

## Postgres Metrics User Provisioning

### SQL (idempotent DO block — Spec FR-31's preferred mechanism)

Run once per NAS via `docker exec`:

```sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mneme_metrics') THEN
    CREATE USER mneme_metrics WITH PASSWORD '<generated-password>';
  ELSE
    ALTER USER mneme_metrics WITH PASSWORD '<generated-password>';
  END IF;
END $$;

GRANT pg_monitor TO mneme_metrics;
```

The DO block handles both first-run (CREATE) and re-run (ALTER) cases — letting an operator regenerate the password and re-run the same command without inventing a separate rotation flow. `GRANT pg_monitor` is unconditional (re-granting an already-held role is a Postgres no-op).

`pg_monitor` is a built-in role in Postgres ≥10 that bundles the read access postgres_exporter needs (`pg_read_all_settings`, `pg_read_all_stats`, `pg_stat_scan_tables`). Mneme runs `pgvector/pgvector:pg16` per its compose, well above the requirement.

### `docs/mneme-setup.md` outline

- **Prerequisites:** Mneme stack deployed and running (Postgres healthy on `localhost:5433`); F002's stack also running (otherwise nothing to integrate with).
- **Step 1: Generate the metrics password.** `openssl rand -base64 24` produces a 32-char URL-safe password. Save somewhere reachable (Portainer's stack environment field; password manager).
- **Step 2: Run the provisioning SQL.** Single `docker exec mneme-postgres-1 psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "..."` invocation with the DO block above. Substitute the generated password into the SQL string before invoking.
- **Step 3: Set `POSTGRES_METRICS_PASSWORD`.** Add the password to nas-observability's Portainer stack environment variables. The compose file's `${POSTGRES_METRICS_PASSWORD}` substitution picks it up on next deploy.
- **Step 4: Verify connectivity.** `psql "postgresql://mneme_metrics:<pw>@localhost:5433/postgres?sslmode=disable" -c "SELECT count(*) FROM pg_stat_database;"` should return a count > 0. If it errors, check the password matches and `pg_monitor` was granted.
- **Step 5: Redeploy nas-observability stack.** Portainer → Update → Re-pull image → deploy. postgres_exporter container should enter `Up`; `mneme-postgres` scrape job should report UP within one scrape cycle.
- **Troubleshooting subsection:** auth failures, role-already-exists (expected on re-run with the DO block — should not surface as an error), `pg_monitor` not granted, `pg_stat_statements` not installed (panel-level concern, not provisioning).

---

## Dashboards

### D4-equivalent traceability table

**No dashboard panel is written until its data source is confirmed in Mneme's deployed `/metrics` output (api + worker) or postgres_exporter v0.16.0's documented metric set (database).**

| Dashboard | Panel | Metric (PromQL intent) | Source | Confirmed |
|---|---|---|---|---|
| api | HTTP Request Rate by Status | `sum by (status) (rate(http_requests_total[5m]))` | Mneme F008 (api) | ✓ verified by operator curl |
| api | HTTP Request Rate by Route (top 10) | `topk(10, sum by (route) (rate(http_requests_total[5m])))` | Mneme F008 (api) | ✓ |
| api | Latency p50 / p95 / p99 | `histogram_quantile(0.5\|0.95\|0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` | Mneme F008 (api) | ✓ |
| api | Error Rate (4xx + 5xx) | `sum(rate(http_requests_total{status=~"4.."}[5m]))` and `{status=~"5.."}` | Mneme F008 (api) | ✓ |
| api | DB Pool: Active vs Idle | `db_pool_connections_active`, `db_pool_connections_idle` (time series) | Mneme F008 (api) | ✓ |
| api | DB Up indicator | `db_up` (stat with mappings: 1=Up green, 0=Down red) | Mneme F008 (api) | ✓ |
| api | Node.js Process: heap, RSS, event-loop lag | `process_resident_memory_bytes`, `nodejs_heap_size_total_bytes`, `nodejs_eventloop_lag_seconds` | prom-client default | ✓ enabled per F008 T002 |
| worker | Heartbeat Freshness (stat) | `time() - worker_heartbeat_timestamp_seconds` (seconds-since-last-heartbeat) | Mneme F008 (worker) | ✓ |
| worker | Heartbeat Freshness (over time) | same as above, time series | Mneme F008 (worker) | ✓ |
| worker | Ingestion Job Counts by State (stat) | `ingestion_jobs_total` by `state` (succeeded / failed / low_confidence) | Mneme F008 (worker) | ✓ pre-registered at zero |
| worker | Ingestion Job Rate by State (time series) | `sum by (state) (rate(ingestion_jobs_total[5m]))` | Mneme F008 (worker) | ✓ |
| worker | Ingestion Duration p50/p95/p99 by parser_type | `histogram_quantile(...) (sum by (le, parser_type) (rate(ingestion_duration_seconds_bucket[5m])))` | Mneme F008 (worker) | ✓ registered, ⏸ unobserved |
| worker | Parser Confidence (heatmap or histogram) | `parser_confidence_bucket` aggregated by `parser_type` | Mneme F008 (worker) | ✓ registered, ⏸ unobserved |
| worker | Node.js Process Metrics | same as api (heap, RSS, event-loop lag) | prom-client default | ✓ |
| database | Active Connections (stat + time series) | `pg_stat_database_numbackends{datname!~"template.*\|postgres"}` | postgres_exporter v0.16.0 | ✓ verified T075 (labels: `{datid, datname}`) |
| database | Connection Pool Saturation | `sum(pg_stat_database_numbackends) / on() group_left() pg_settings_max_connections * 100` (label-bridge needed: numbackends has `{datid, datname}`, max_connections has `{server}` only) | postgres_exporter v0.16.0 | ✓ verified T075 (saturation PromQL adjusted from naïve division to bridge mismatched label sets) |
| database | Transaction Rate (commit + rollback) | `rate(pg_stat_database_xact_commit[5m]) + rate(pg_stat_database_xact_rollback[5m])` | postgres_exporter v0.16.0 | ✓ verified T075 |
| database | Cache Hit Ratio | `pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read) * 100` | postgres_exporter v0.16.0 | ✓ verified T075 |
| database | Slow Queries (count by query_id) | `topk(10, pg_stat_statements_calls)` — **requires `pg_stat_statements` extension** | postgres_exporter v0.16.0 | ⏸ verified absent T075 (extension not installed in Mneme's Postgres; `noValue` config on panel per spec scenario 7) |
| database | Database Size (per database) | `pg_database_size_bytes{datname!~"template.*"}` | postgres_exporter v0.16.0 | ✓ verified T075 (labels: `{datname}` only — no `datid`, asymmetric vs `pg_stat_database_*`) |

**Verification at impl time:** the api/worker rows are confirmed via the operator's spec-time curl. The database rows depend on postgres_exporter v0.16.0's metric naming. Plan-time task: pull the image, run `curl -s http://localhost:9187/metrics | grep -E "^# HELP" | head -50` to confirm the actual exposed metric names match this table. Any divergence from this table gets fixed before the dashboard JSONs reference the metric.

**T075 outcome (2026-04-25):** all six database-row metric names verified live against postgres_exporter v0.16.0 talking to Mneme's Postgres on the DS224+. Zero renames vs. plan; label sets surfaced two impl notes captured in the table above:
- `pg_settings_max_connections` carries only `{server="localhost:5433"}` — no `datname`. The Connection Pool Saturation panel needs `on()` or `ignoring(datname, datid)` to reconcile the label sets; naïve element-wise division across `pg_stat_database_numbackends / pg_settings_max_connections` returns empty.
- `pg_database_size_bytes` carries `{datname}` only (no `datid`), unlike `pg_stat_database_*` which expose both. Panels mixing the two metrics must avoid joining on `datid`.
- `pg_stat_statements_calls` absent — extension not installed in Mneme's Postgres. Slow Queries panel will render with the `noValue` string per Spec scenario 7 (option (c) in §"No data" mechanism below). Operator can optionally enable the extension per `docs/mneme-setup.md` troubleshooting; not required for F003 completion.

**Anti-pattern defense:** any panel whose metric isn't in either source (Mneme `/metrics` or postgres_exporter `/metrics`) gets dropped before the dashboard JSON ships. Same discipline as F002's D4 traceability gate (T041).

### "No data" mechanism for `pg_stat_statements`-dependent panels (Spec scenario 7)

Three options the spec deferred to plan:

- **(a) Adjacent text panel** in the same row, explaining "Slow query metrics require pg_stat_statements; see docs/mneme-setup.md to enable."
- **(b) Panel-level `description`** rendered in the info-icon tooltip on hover. Only visible if user hovers; less discoverable but non-intrusive.
- **(c) Panel `noValue` config** showing a custom string (e.g., "pg_stat_statements not installed") instead of Grafana's default "no data."

**Plan picks (c) `noValue` config** — it's the cleanest UX (the panel itself communicates the prerequisite), survives Grafana version upgrades better than text-panel layout assumptions, and doesn't waste row space on text panels. The slow-queries panel sets `fieldConfig.defaults.noValue: "pg_stat_statements extension not installed — see docs/mneme-setup.md to enable"`.

### Per-dashboard composition

**`mneme/api.json`** — 7 panels:
- Row 1 (h=4): db_up (stat), HTTP request rate (stat), 5xx error rate (stat) — at-a-glance health
- Row 2 (h=8): HTTP request rate by status (time series), HTTP request rate by route top-10 (time series)
- Row 3 (h=8): Latency p50/p95/p99 (time series, multi-line)
- Row 4 (h=6): DB pool active/idle (time series), Node.js process metrics (time series)
- Tags: `[mneme, api]`. uid: `mneme-api`. Title: `Mneme — API`.

**`mneme/worker.json`** — 7 panels (per Spec D8, single dashboard for now):
- Row 1 (h=4): Heartbeat freshness (stat with thresholds: green <30s, yellow 30-120s, red >120s)
- Row 2 (h=6): Heartbeat freshness over time (time series)
- Row 3 (h=4): Ingestion job counts by state (stat × 3: succeeded, failed, low_confidence)
- Row 4 (h=8): Ingestion job rate by state (time series), Ingestion duration p50/p95/p99 by parser_type (time series)
- Row 5 (h=6): Parser confidence histogram (heatmap), Node.js process metrics (time series)
- Tags: `[mneme, worker]`. uid: `mneme-worker`. Title: `Mneme — Worker`.

**`mneme/database.json`** — 6 panels:
- Row 1 (h=4): Active connections (stat), Connection pool saturation (stat with thresholds), Database size (stat)
- Row 2 (h=8): Active connections over time (time series), Transaction rate over time (time series)
- Row 3 (h=8): Cache hit ratio over time (time series, percent), Slow queries top-10 (table — `noValue` configured for missing pg_stat_statements)
- Tags: `[mneme, database]`. uid: `mneme-database`. Title: `Mneme — Database`.

### Authoring workflow

Per Spec FR-38 — same as F001/F002, with one F003 simplification: the deployed NAS Grafana is LAN-reachable at `http://<nas-ip>:3030` directly because the stack uses host networking, so no local Grafana / no SSH tunnel is needed. Edit directly against the deployed instance.

1. Open the deployed Grafana in a browser at `http://<nas-ip>:3030`. With `editable: true` set in the dashboard JSON, panel-level edits are available in the UI. (No need to spin up a local Grafana or tunnel Prometheus through SSH — the F001/F002 plans documented that pattern but neither feature actually needed it, and DSM blocks SSH TCP forwarding by default anyway.)
2. Iterate panels in the UI until they render correctly with real data.
3. Export JSON via Grafana's "Save dashboard → JSON Model" UI.
4. **Run through `scripts/strip-grafana-export-noise.sh <file>` to remove the four export-environment keys** (FR-39).
5. Set `editable: false` at the dashboard level.
6. Verify `datasource.uid: "prometheus"` on every panel target (FR-37).
7. Verify tags match the convention (`[mneme, api]`, etc.).
8. Verify uid matches the file slug (`mneme-api`, `mneme-worker`, `mneme-database`).
9. Commit under `docker/grafana/dashboards/mneme/`.

---

## Provisioner Configuration

### `docker/grafana/provisioning/dashboards/dashboards.yaml` diff

Add `foldersFromFilesStructure: true` under `options:`:

```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/dashboards
      foldersFromFilesStructure: true   # NEW
```

**Empirically verified working on Grafana 11.4.0 during pre-spec investigation:** local 5-min test created three folders from three subdirectories; dashboards correctly assigned. No regression risk.

### Dockerfile path update

The current `docker/grafana/Dockerfile` has:
```
COPY scripts/inject-build-metadata.sh /tmp/inject-build-metadata.sh
RUN sh /tmp/inject-build-metadata.sh "${VERSION}" "${GIT_SHA}" /etc/grafana/dashboards/stack-health.json && rm /tmp/inject-build-metadata.sh
```

Update to reflect post-migration path:
```
RUN sh /tmp/inject-build-metadata.sh "${VERSION}" "${GIT_SHA}" /etc/grafana/dashboards/stack/stack-health.json && rm /tmp/inject-build-metadata.sh
```

The `COPY dashboards/ /etc/grafana/dashboards/` directive doesn't need updating — it copies the directory tree as-is, including the new subfolders.

---

## Strip Script

### `scripts/strip-grafana-export-noise.sh`

Port verbatim from Mneme's `ops/scripts/strip-grafana-export-noise.sh`:

```bash
#!/bin/bash
# Removes the four export-environment keys Grafana injects on every JSON
# export (__inputs, __elements, __requires, iteration). Keeps committed
# dashboard diffs limited to real content (panels, queries, layout).
#
# Usage: ./scripts/strip-grafana-export-noise.sh path/to/dashboard.json
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <dashboard.json>" >&2
  exit 2
fi

target="$1"

if [ ! -f "$target" ]; then
  echo "ERROR: file not found: $target" >&2
  exit 1
fi

jq 'del(.__inputs, .__elements, .__requires, .iteration)' "$target" > "$target.tmp"
mv "$target.tmp" "$target"
echo "Stripped export-environment keys from $target"
```

Mode 100755. Same shebang and `set -euo pipefail` discipline as `init-nas-paths.sh` and `diagnose.sh`.

`docs/deploy.md` gains a note under "Authoring dashboards" pointing at the script.

---

## Implementation Phases

Decomposed in detail in [`tasks.md`](./tasks.md) (next). High-level shape:

**0. Pre-merge gates** — F003-unique. Two checks before any Phase 1 task starts (or in parallel with Phase 1):
   - Verify Mneme's `docs/observability.md` has landed on Mneme's `main` branch and its dashboard-ownership language matches v1.2.
   - Smoke-test Mneme's `/metrics` endpoints on the deployed NAS to confirm the metric names referenced in the traceability table actually exist (`http_requests_total`, `db_up`, `worker_heartbeat_timestamp_seconds`, etc.). If any are missing or renamed, traceability table updates before dashboards are authored.

**1. Operator runbook + provisioning execution** — write `docs/mneme-setup.md`, operator runs the SQL on the NAS to create `mneme_metrics`, sets `POSTGRES_METRICS_PASSWORD` in Portainer.

**2. Strip script port** — `scripts/strip-grafana-export-noise.sh` lands early so Phase 6's dashboard authoring uses it from the start.

**3. Subfolder migration** — `git mv` of F001/F002 dashboards into `stack/` and `synology/`. Provisioner config updated. Dockerfile path updated. Local Grafana build test confirms all four pre-F003 dashboards still render before any F003 dashboards exist.

**4. Compose, scrape config, supporting docs** — postgres_exporter service added; mneme-* scrape jobs added; memory rebalance applied; `docs/ports.md` updated; `.env.example` updated with `POSTGRES_METRICS_PASSWORD` comment; `docs/setup.md` cross-references mneme-setup.md.

**5. Dashboard traceability table verification** — postgres_exporter v0.16.0 metric names cross-checked against the database dashboard's intended PromQL. Any divergence updates the table; any panel without a confirmed metric is dropped.

**6. Mneme dashboards authored** — three dashboards iterated in the deployed NAS Grafana (LAN-reachable directly via host networking; no SSH tunnel), exported, stripped, committed under `docker/grafana/dashboards/mneme/`.

**7. DS224+ deploy + acceptance** — operator-driven. Re-pull image, redeploy, walk through Spec scenarios 2-10. `diagnose.sh` is the first-line tool if anything misbehaves.

**8. 24-hour stability observation** — match F002's discipline. Mneme `/metrics` baseline is well-characterized but postgres_exporter scraping in production is net-new; diurnal patterns (Hyper Backup, day/night usage variance) need the full window.

Phase 0 and Phase 5 are the F003-equivalent of F002's D3 / D4 gates — pre-implementation discipline that prevents shipping panels against metrics that don't exist.

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Mneme F008 T013 doesn't land in time | Medium | Phase 0 enforces the gate. If T013 is blocked, F003 PR is held until it ships. F002's retrospective Path A vs Path B framing already covered this. |
| postgres_exporter v0.16.0 metric names diverge from this plan's traceability table | Medium | Phase 5 cross-checks before dashboards are authored. Any divergence updates the table; panels for missing metrics are dropped (D4 anti-pattern defense). |
| Memory donor-trim: cAdvisor's 60M cap proves tight under unusual NAS load | Low | Per Spec D5 + plan cross-reference: future trims target grafana or node_exporter, NOT cAdvisor. If cAdvisor genuinely needs more, donate from grafana (39% headroom currently) — doesn't violate budget. |
| postgres_exporter can't authenticate to Mneme's Postgres | Low | Phase 1 includes a connectivity verification step (psql connection test) before postgres_exporter ever runs in compose. |
| Subfolder migration breaks Dockerfile build | Low | Phase 3 includes a local build test on the post-migration tree before merging. |
| `pg_stat_statements` extension absent → slow-query panels render with no-data | Expected by design | `noValue` config on the panel surfaces the prerequisite explicitly; not a failure mode, just a feature-flag UX. |
| Mneme's Postgres `POSTGRES_DB` value differs from expectations | Very low | postgres_exporter connects to `postgres` system DB, not Mneme's app DB — sidesteps the dependency. Documented above. |
| `honor_labels: true` accidentally applied to `mneme-postgres` (or omitted from a future consumer that needs it) | Low — CI-enforced | The count-gate CI step (see §`honor_labels` count gate) fails the build when the count drifts from `expected`. F004+ feature PRs update `expected` if their consumers legitimately need `honor_labels`. |
| Phase 0's Mneme `/metrics` smoke-test surfaces a missed metric | Low (verified at spec time) | Already verified by operator curl during scoping; Phase 0 is the formal verification. If a metric is missing, the panel using it is dropped; possibly surfaces a Mneme-side gap worth flagging. |

---

## Dependencies

**Constitution v1.2.0** ratified (commit `b9c7341` on 2026-04-26). v1.2's "Per-application dashboards" Platform Constraint is the reason F003 looks the way it does.

**Mneme F008 T001-T009 deployed on the NAS.** Verified at spec time:
- `/metrics` reachable at `localhost:3000` (api) and `localhost:3001` (worker)
- Baseline labels (`service`, `job`, `instance`) present on every metric line
- `db_up` confirmed shipped (`db_up{service="mneme",job="mneme-api",instance="DS224plus:3000"} 1`)
- Deployed Mneme matches Mneme `main` HEAD `673d42e`

**Mneme F008 T013** (`docs/observability.md`) **pending in Mneme parallel work stream**. F003 Phase 0 verifies it has landed and matches v1.2 before F003's PR can merge. If T013 is significantly delayed, F003 work continues but the PR is held.

**Mneme's Postgres exposed on `localhost:5433`.** Verified at spec time via Mneme's compose (`pgvector/pgvector:pg16` running `network_mode: host`, `command: ["postgres", "-c", "port=${MNEME_PG_PORT:-5433}"]`). No Mneme compose change required.

**Downstream features depend on F003:**
- **Alerting feature** — Mneme alerts (`MnemeWorkerDown`, `MnemeDatabaseUnreachable`, `MnemeApiHighErrorRate`) reference metrics F003 makes scrape-able. The alerting feature also resolves the rules-file-sync question Mneme F008 T010 leaves open.
- **F004+ consumer apps** (Pinchflat, Immich, etc.) — F003 establishes the per-application pattern (subfolder, scrape job, optional `honor_labels: true`, dashboard authoring workflow). F004 follows the same template.
