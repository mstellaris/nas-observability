# Tasks: Mneme Application Scraping & Dashboards

**Feature Branch:** `003-mneme-app-scraping`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

28 tasks organized into 9 phases (Phase 0 + Phases 1–8), numbered T057–T084 (continuing F002's sequence). Tasks marked `[P]` can run in parallel with other `[P]` tasks in the same phase.

**Phase 0 is F003-unique** — it enforces the cross-repo gate on Mneme F008 T013 plus a smoke-test of Mneme's deployed `/metrics` endpoints. Phase 0 must complete before Phase 6 (dashboard authoring) starts; if T013 hasn't landed, Phase 6 stays blocked while Phases 1–5 can proceed.

Phase ordering deliberately keeps the strip-script port early (Phase 2) so dashboard authoring (Phase 6) uses it from the start, and the subfolder migration (Phase 3) before authoring so new Mneme dashboards land in their final paths from inception.

**Total:** 29 tasks across 9 phases (T057–T085).
**Parallelizable:** 3 marked `[P]` (T076–T078, the three Mneme dashboards in Phase 6).
**Phase 8 (T083 + T084) is observation-only:** anomalies generate follow-up issues, do not block F003 close — mirrors F001 T028 / F002 T056 pattern.
**Note on T085 numbering:** T085 (retrospective stub) is numerically last but executes between T082 (Phase 7 close) and T083 (Phase 8 start). File order reflects execution order, not numerical order — a deliberate trade-off to keep stable cross-references if the task list is later split or reorganized.

---

## Phase 0: Pre-Merge Gates (F003-unique)

The cross-repo coordination + metric-name verification gates. Phase 0 is operator-driven for the cross-repo checks; the smoke-test is automated. None of these are blocking for Phases 1–5; they ARE blocking for Phase 6 (dashboard authoring) because dashboards depend on metrics that Phase 0 confirms exist.

**Phase 0 runs in parallel with Phases 1–5.** T057, T058, T059 can complete any time before Phase 6 starts (where T075's traceability gate consumes Phase 0's smoke-test result). **Recommended ordering within Phase 0:** T057 first (binary pass/blocked — cheapest check); if T057 passes, then T058 + T059 in parallel (T058 is the substantive cross-read; T059 is the live curl). If T057 fails, T058 is moot (nothing to cross-read), but T059 can still run independently against the deployed Mneme.

### T057 — Verify Mneme F008 T013 has landed

**Files:** (none; verification-only)

**Acceptance:**

**Given** Mneme's parallel work stream is shipping T013 (`docs/observability.md`) per F008 plan
**When** the operator checks Mneme's `main` branch
**Then** `/Users/stellar/Code/mneme/docs/observability.md` exists (`git -C /Users/stellar/Code/mneme log --oneline | grep T013` returns at least one matching commit)
**And** if the file does not exist, F003's PR merge is held until T013 lands; Phases 1–5 can proceed in the meantime
**And** the verification result (passed / blocked) is recorded in the F003 PR description

### T058 — Verify Mneme T013's language matches Constitution v1.2

**Files:** (none; verification-only)

**Acceptance:**

**Given** T057 has confirmed `docs/observability.md` exists in Mneme
**When** the operator cross-reads Mneme's `docs/observability.md` against `.specify/memory/constitution.md` v1.2's "Per-application dashboards" Platform Constraint
**Then** Mneme's doc says (or equivalently states): consumers own the `/metrics` contract; nas-observability owns the visualization (and future alerting) layer; dashboards live in nas-observability under `docker/grafana/dashboards/<consumer-slug>/`; no cross-repo sync mechanism exists
**And** if the language drifts (e.g., still asserts dashboards live in Mneme's repo), the discrepancy is resolved before F003 merges — either Mneme amends T013 to align, or v1.2 is revisited
**And** the cross-read outcome (aligned / divergent) is recorded in the F003 PR description

### T059 — Smoke-test Mneme's deployed `/metrics` endpoints

**Files:** (none; verification-only — output captured in PR description)

**Acceptance:**

**Given** Mneme F008 T001–T009 are deployed on the NAS (verified at spec time; `db_up` returned `1`)
**When** the operator (or local script via SSH) curls Mneme's `/metrics` endpoints:
```bash
curl -s http://<nas-ip>:3000/metrics | grep -E '^http_requests_total|^http_request_duration_seconds_bucket|^db_up|^db_pool_connections_(active|idle)'
curl -s http://<nas-ip>:3001/metrics | grep -E '^worker_heartbeat_timestamp_seconds|^ingestion_jobs_total|^ingestion_duration_seconds_bucket|^parser_confidence_bucket'
```
**Then** every metric name referenced in `plan.md` §D4 traceability table for the api and worker dashboards returns at least one series (or pre-registered zero, in the case of `ingestion_jobs_total{state="..."}` which is shipped at zero before any ingestions have run)
**And** baseline labels (`service="mneme"`, `job="mneme-api"` or `mneme-worker"`, `instance="DS224plus:<port>"`) are present on every series
**And** if any metric is missing, the traceability table's row for the affected panel is updated (panel dropped or query revised) before Phase 6 begins
**And** the smoke-test output is captured in the PR description for traceability

---

## Phase 1: Operator Runbook + Provisioning

Lands `docs/mneme-setup.md` and the operator runs the SQL provisioning. Phase 1 can run in parallel with Phases 2–4 (no file conflicts).

### T060 — Write `docs/mneme-setup.md`

**Files:** `docs/mneme-setup.md`

**Acceptance:**

**Given** Mneme's Postgres is running on `localhost:5433` (verified during spec scoping)
**When** `docs/mneme-setup.md` is written
**Then** the runbook covers Plan §`docs/mneme-setup.md` outline's five steps: (1) generate metrics password (`openssl rand -base64 24`), (2) run the DO-block SQL via `docker exec mneme-postgres-1 psql ...`, (3) set `POSTGRES_METRICS_PASSWORD` in Portainer stack env, (4) verify connectivity (`psql "postgresql://mneme_metrics:<pw>@localhost:5433/postgres?sslmode=disable" -c "SELECT count(*) FROM pg_stat_database;"`), (5) redeploy nas-observability stack
**And** the SQL is the idempotent DO block from Plan §Postgres Metrics User Provisioning (CREATE-or-ALTER, then GRANT pg_monitor) — re-runnable with a rotated password without state corruption
**And** Troubleshooting subsection covers: auth failure, role already exists (which the DO block handles silently — flagged as expected on re-run), `pg_monitor` not granted, `pg_stat_statements` extension not installed (panel-level concern; pointer to dashboard's `noValue` panel-config behavior)
**And** cross-reference to `docs/setup.md` for first-time stack setup

### T061 — Operator generates password and runs the provisioning SQL

**Files:** (none; operational, NAS-side action)

**Acceptance:**

**Given** `docs/mneme-setup.md` is committed to `main` (T060) and Mneme's Postgres is running
**When** the operator follows Steps 1–2 of the runbook on the NAS
**Then** a password is generated via `openssl rand -base64 24` (or equivalent — 24+ random characters)
**And** running the DO-block SQL via `docker exec mneme-postgres-1 psql ...` succeeds without error (CREATE on first run; ALTER on subsequent runs)
**And** `\du` in psql shows `mneme_metrics` with `Member of: pg_monitor`
**And** the password is saved somewhere reachable for Step 3 (Portainer env field; password manager)

### T062 — Operator sets `POSTGRES_METRICS_PASSWORD` in Portainer stack environment

**Files:** (none; operational)

**Acceptance:**

**Given** T061 produced a generated password
**When** the operator opens nas-observability's Portainer stack and adds `POSTGRES_METRICS_PASSWORD=<generated>` to the stack environment variables
**Then** the password is saved to Portainer's encrypted env store (visible to the operator, not in clear-text logs)
**And** it is NOT committed to the repo's `.env.example` (only the variable name is documented there with a cross-reference comment)

### T063 — Operator verifies metrics-user connectivity

**Files:** (none; operational)

**Acceptance:**

**Given** T061 + T062 are complete
**When** the operator runs `psql "postgresql://mneme_metrics:<pw>@localhost:5433/postgres?sslmode=disable" -c "SELECT count(*) FROM pg_stat_database;"` from the NAS shell
**Then** the query returns a non-zero count (typically 4–8 for the system + Mneme databases)
**And** if connectivity fails (auth, role, network), the operator iterates back to T061's SQL or T062's password — fixing the root cause before continuing to Phase 7

---

## Phase 2: Strip Script Port

### T064 — Port `scripts/strip-grafana-export-noise.sh` from Mneme

**Files:** `scripts/strip-grafana-export-noise.sh`, `docs/deploy.md`

**Acceptance:**

**Given** Mneme has the script at `/Users/stellar/Code/mneme/ops/scripts/strip-grafana-export-noise.sh`
**When** the script is ported to nas-observability
**Then** the file matches Plan §Strip Script's snippet exactly (single `jq 'del(.__inputs, .__elements, .__requires, .iteration)'` invocation with `set -euo pipefail`, error handling for missing file argument, mode 100755)
**And** `bash -n scripts/strip-grafana-export-noise.sh` passes
**And** `git ls-files --stage scripts/strip-grafana-export-noise.sh` shows mode `100755`
**And** `docs/deploy.md` gains an "Authoring Mneme dashboards" note pointing at the script as the export-cleanup step

---

## Phase 3: Subfolder Migration

### T065 — `git mv` four F001/F002 dashboards into subfolders

**Files:** `docker/grafana/dashboards/{stack,synology}/*` (renamed from flat layout)

**Acceptance:**

**Given** F002's flat dashboard layout under `docker/grafana/dashboards/`
**When** the migration runs:
```bash
mkdir -p docker/grafana/dashboards/{stack,synology,mneme}
git mv docker/grafana/dashboards/stack-health.json docker/grafana/dashboards/stack/
git mv docker/grafana/dashboards/nas-overview.json docker/grafana/dashboards/synology/
git mv docker/grafana/dashboards/storage-volumes.json docker/grafana/dashboards/synology/
git mv docker/grafana/dashboards/network-temperature.json docker/grafana/dashboards/synology/
```
**Then** four files are renamed (not delete-add); `git status` shows them as renamed with 100% similarity
**And** `git log --follow docker/grafana/dashboards/stack/stack-health.json` traces back through F001's original creation
**And** the dashboards' content is unchanged (panel JSON identical to pre-F003 state)
**And** the empty `mneme/` directory exists for Phase 6 to populate (with a `.gitkeep` if Git refuses to track an empty dir)

### T066 — Add `foldersFromFilesStructure: true` to dashboard provisioner

**Files:** `docker/grafana/provisioning/dashboards/dashboards.yaml`

**Acceptance:**

**Given** the existing provisioner config from F001
**When** the config is updated per Plan §Provisioner Configuration
**Then** the file gains `foldersFromFilesStructure: true` under `options:` (single new line; nothing else changes)
**And** Python YAML parse (`python3 -c "import yaml; yaml.safe_load(open('...'))"`) passes
**And** the rest of the provider block (apiVersion, name, orgId, folder, type, disableDeletion, updateIntervalSeconds, allowUiUpdates, options.path) is unchanged

### T067 — Update Dockerfile inject-build-metadata path

**Files:** `docker/grafana/Dockerfile`

**Acceptance:**

**Given** the Dockerfile invokes `inject-build-metadata.sh` with the F001/F002-era path `/etc/grafana/dashboards/stack-health.json`
**When** the path is updated post-migration
**Then** the Dockerfile invokes the script with `/etc/grafana/dashboards/stack/stack-health.json` (the post-migration location)
**And** no other Dockerfile content changes (the `COPY dashboards/ /etc/grafana/dashboards/` directive correctly copies the new directory tree as-is)
**And** `docker build --build-arg VERSION=test --build-arg GIT_SHA=test docker/grafana/` succeeds locally
**And** T065 and T067 MUST land in the same commit (or T067 immediately after T065 in the same PR — never T067 alone). Splitting them leaves an intermediate state where the Dockerfile points at a path that doesn't exist yet, breaking the build. Claude Code's `/implement` workflow may default to one commit per task; this acceptance bullet guards against that exact failure mode

### T068 — Local Grafana build test post-migration

**Files:** (none; validation-only — same shape as F002 T051)

**Acceptance:**

**Given** T065–T067 are committed and the Dockerfile builds (verified in T067)
**When** the operator runs the image locally with an empty bind mount simulating prod:
```bash
docker run -d --name grafana-f003-test -p 3035:3000 \
  -v /tmp/grafana-f003-test:/var/lib/grafana \
  -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=testpw \
  nas-observability-grafana:local
```
**Then** all four pre-F003 dashboards are visible via `curl -u admin:testpw http://localhost:3035/api/search?type=dash-db` (count = 4)
**And** `curl -u admin:testpw http://localhost:3035/api/folders` returns two folders: `stack` and `synology` (no `mneme` yet — Phase 6 hasn't run)
**And** the `stack-health` dashboard's Build Metadata panel still shows the substituted VERSION + GIT_SHA tokens (T067 path update worked)
**And** test cleanup: `docker rm -f grafana-f003-test`

---

## Phase 4: Compose, Scrape Config, Supporting Docs

### T069 — Add `postgres-exporter` service to `docker-compose.yml`

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** F002's five-service compose
**When** `postgres-exporter` is added per Plan §Service Configuration: postgres_exporter
**Then** the service uses `image: quay.io/prometheuscommunity/postgres-exporter:v0.16.0` (verify tag exists at impl time via `docker manifest inspect`)
**And** `network_mode: host`, `restart: unless-stopped`, `mem_limit: 50M`
**And** `environment: - DATA_SOURCE_NAME=postgresql://mneme_metrics:${POSTGRES_METRICS_PASSWORD}@localhost:5433/postgres?sslmode=disable`
**And** NO `user:` override (image default per FR-42 — postgres_exporter is stateless)
**And** NO `volumes:` (stateless)
**And** NO `healthcheck:` (per Plan: distroless image lacks wget/curl; comment in compose explains the rationale)
**And** `docker compose config` parses cleanly with the new service

### T070 — Apply memory donor-trim in compose

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** F002's existing `mem_limit` values
**When** the donor-trim is applied per Plan §Memory Budget
**Then** `cadvisor` `mem_limit` changes from `90M` to `60M`
**And** `node-exporter` `mem_limit` changes from `50M` to `30M`
**And** all other services' `mem_limit` values are unchanged
**And** `docker compose config` shows total `mem_limit` sum = `629145600` bytes = exactly 600 MiB

### T071 — Add three Mneme scrape jobs to `prometheus.yml`

**Files:** `config/prometheus/prometheus.yml`

**Acceptance:**

**Given** F002's four scrape jobs
**When** three new jobs are added per Plan §Prometheus Scrape Jobs
**Then** `mneme-api` declares `honor_labels: true`, `scrape_interval: 15s`, `static_configs: targets: ['localhost:3000']`
**And** `mneme-worker` declares `honor_labels: true`, `scrape_interval: 15s`, `static_configs: targets: ['localhost:3001']`
**And** `mneme-postgres` declares `scrape_interval: 30s`, `static_configs: targets: ['localhost:9187']`, **WITHOUT** `honor_labels: true` (postgres_exporter doesn't bake `instance` per FR-33)
**And** F001/F002's existing four scrape jobs (prometheus, node_exporter, cadvisor, synology) are unchanged
**And** `grep -c "honor_labels: true" config/prometheus/prometheus.yml` returns `2`

### T072 — Add `honor_labels` count-gate CI step

**Files:** `.github/workflows/build-grafana-image.yml`

**Acceptance:**

**Given** F002's existing build workflow
**When** the gate step is added per Plan §`honor_labels` count gate (CI-enforced)
**Then** a new `Verify honor_labels count in prometheus.yml` step lands in the `build-and-push` job (before the docker build step)
**And** the step's bash compares `grep -c '^[[:space:]]*honor_labels: true' config/prometheus/prometheus.yml` against `expected=2` (with explanatory comment that F004+ feature PRs update `expected` if they add consumer-app scrape jobs)
**And** the workflow's `paths:` trigger filter is extended to include `config/prometheus/prometheus.yml`
**And** running the step against the post-T071 prometheus.yml passes (count 2 = expected 2)
**And** running the step against a deliberately-broken prometheus.yml (3 occurrences) fails with the documented `::error::` message

### T073 — Update supporting docs

**Files:** `docs/ports.md`, `.env.example`, `docs/setup.md`, `docs/deploy.md`

**Acceptance:**

**Given** F002's docs reflect the five-service stack
**When** F003's small doc updates land
**Then** `docs/ports.md` moves `9187` from "Reserved for later features" to "Current assignments" with F003 as the claiming feature (Mneme — note: `9187` is shared between F003-Mneme-Postgres and any future feature reusing postgres_exporter on a different DB; if needed, F004+ adjusts the assignment table)
**And** `.env.example` adds a comment block documenting `POSTGRES_METRICS_PASSWORD` (matching the F002 `SYNOLOGY_SNMP_COMMUNITY` comment pattern: `# POSTGRES_METRICS_PASSWORD is set in Portainer stack environment, NOT in this file. See docs/mneme-setup.md §Step 3.`)
**And** `docs/setup.md` gains a one-line cross-reference under "What F002 does not ship" pointing at `docs/mneme-setup.md`
**And** `docs/deploy.md` gains an "Updating Mneme dashboards" subsection mirroring F002's "Updating snmp.yml" pattern (workflow: edit JSON in `docker/grafana/dashboards/mneme/`, run through strip script, commit, image rebuilds, redeploy)

### T074 — Compose + prometheus validation

**Files:** (none; validation-only)

**Acceptance:**

**Given** T069–T073 are committed
**When** validation runs:
```bash
docker compose config 2>&1 > /dev/null && echo "compose: OK"
grep -c "honor_labels: true" config/prometheus/prometheus.yml  # expect 2
docker compose config 2>&1 | grep "mem_limit:" | awk -F'"' '{sum+=$2} END {print "Total: " sum}'  # expect 629145600
docker compose config 2>&1 | grep -c "network_mode: host"  # expect 6
```
**Then** all four checks pass
**And** if any fail, the validation result is documented in the PR description and the underlying issue resolved before merge

---

## Phase 5: Dashboard Traceability Verification (Gate for Phase 6)

### T075 — Cross-check postgres_exporter v0.16.0 metric names against database dashboard PromQL

**Files:** `specs/003-mneme-app-scraping/plan.md` (update §D4 traceability table if divergence)

**Acceptance:**

**Given** the database dashboard's PromQL intent in Plan §D4 traceability table (rows marked "needs verify @ impl")
**When** the operator runs:
```bash
docker pull quay.io/prometheuscommunity/postgres-exporter:v0.16.0
# Spin up a temporary instance pointing at Mneme's Postgres with the metrics user
docker run -d --name pg-exporter-test --network host \
  -e DATA_SOURCE_NAME="postgresql://mneme_metrics:<pw>@localhost:5433/postgres?sslmode=disable" \
  quay.io/prometheuscommunity/postgres-exporter:v0.16.0
sleep 5
curl -s http://localhost:9187/metrics | grep -E "^pg_stat_database_(numbackends|xact_commit|xact_rollback|blks_hit|blks_read)|^pg_settings_max_connections|^pg_database_size_bytes|^pg_stat_statements_calls"
docker rm -f pg-exporter-test
```
**Then** every metric name referenced in the database dashboard's table rows is present in the live output
**And** if any metric is renamed in v0.16.0 (e.g., older versions called it `pg_stat_database_active_connections` in places), the traceability table is updated and the dashboard PromQL adjusted before Phase 6
**And** if `pg_stat_statements_calls` is absent (extension not installed), the slow-queries panel's `noValue` config behavior is confirmed (already specified in Plan §"No data" mechanism)
**And** the verified-against-v0.16.0 traceability table is committed to plan.md before Phase 6 starts

**Gate:** Phase 6 (dashboard authoring) does NOT begin until this task is complete. Same anti-pattern defense as F002's T041 D4 traceability gate.

---

## Phase 6: Mneme Dashboards (3 parallel + 1 verification)

**Gate:** T075 must complete before any task in this phase begins.

### T076 [P] — Author `mneme/api.json`

**Files:** `docker/grafana/dashboards/mneme/api.json`

**Acceptance:**

**Given** the traceability table confirms every panel's metric source
**When** the operator authors the API dashboard in local Grafana (via SSH tunnel to NAS Prometheus, `editable: true`), iterates panels until renders are correct, exports JSON, runs through `scripts/strip-grafana-export-noise.sh`
**Then** the final JSON has 7 panels per Plan §`mneme/api.json` composition (db_up stat, request rate stat, 5xx stat, request rate by status time series, request rate by route top-10, latency p50/p95/p99 time series, db pool active/idle time series + Node.js process metrics)
**And** `uid: "mneme-api"`, `title: "Mneme — API"`, `tags: ["mneme", "api"]`, schemaVersion 39
**And** every panel target declares `datasource.uid: "prometheus"` (FR-37)
**And** `editable: false` at dashboard level (F001 lockdown pattern)
**And** the four export-environment keys (`__inputs`, `__elements`, `__requires`, `iteration`) are absent (strip script applied)
**And** every PromQL query references a metric confirmed in T059's smoke-test or T075's pg_exporter verification

### T077 [P] — Author `mneme/worker.json`

**Files:** `docker/grafana/dashboards/mneme/worker.json`

**Acceptance:**

**Given** the traceability table confirms every panel's metric source
**When** the operator authors the worker dashboard following the same workflow as T076
**Then** the final JSON has 7 panels per Plan §`mneme/worker.json` composition (heartbeat freshness stat, heartbeat freshness time series, ingestion job counts by state stat × 3, ingestion job rate by state time series, ingestion duration p50/p95/p99 time series, parser confidence heatmap, Node.js process metrics)
**And** `uid: "mneme-worker"`, `title: "Mneme — Worker"`, `tags: ["mneme", "worker"]`, schemaVersion 39
**And** the heartbeat-freshness stat uses thresholds: green <30s, yellow 30–120s, red >120s (mirroring future MnemeWorkerDown alert's `> 5m` threshold but tighter for at-a-glance)
**And** all per-panel discipline (datasource.uid, editable:false, strip-script applied) matches T076

### T078 [P] — Author `mneme/database.json`

**Files:** `docker/grafana/dashboards/mneme/database.json`

**Acceptance:**

**Given** T075 confirmed postgres_exporter v0.16.0 metric names
**When** the operator authors the database dashboard
**Then** the final JSON has 6 panels per Plan §`mneme/database.json` composition (active connections stat + time series, connection pool saturation stat with thresholds, transaction rate time series, cache hit ratio time series, slow queries top-10 table, database size stat)
**And** the slow-queries panel's `fieldConfig.defaults.noValue` is set to a custom string (e.g., "pg_stat_statements extension not installed — see docs/mneme-setup.md to enable") per Plan §"No data" mechanism (option c)
**And** `uid: "mneme-database"`, `title: "Mneme — Database"`, `tags: ["mneme", "database"]`, schemaVersion 39
**And** all per-panel discipline matches T076 / T077

### T079 — Local Grafana build test confirms all 7 dashboards visible

**Files:** (none; validation-only)

**Acceptance:**

**Given** T076–T078 committed the three Mneme dashboards under `docker/grafana/dashboards/mneme/`
**When** the operator runs `docker build --build-arg VERSION=<v> --build-arg GIT_SHA=<sha> -t nas-observability-grafana:local docker/grafana/` and starts the image with an empty bind mount (simulating prod)
**Then** `curl -u admin:testpw http://localhost:3035/api/folders` returns three folders: `stack`, `synology`, `mneme`
**And** `curl -u admin:testpw http://localhost:3035/api/search?type=dash-db` returns 7 dashboards (4 pre-F003 + 3 new)
**And** `curl -u admin:testpw "http://localhost:3035/api/search?tag=mneme"` returns the three new dashboards with correct folder assignment
**And** `curl -u admin:testpw "http://localhost:3035/api/search?tag=stack-health"` still returns F001's dashboard (regression check)
**And** Grafana logs show no provisioning errors; opening each dashboard via UI shows its panels structured correctly (no "datasource not found" or schema warnings)

---

## Phase 7: DS224+ Deploy & Acceptance

**Pause checkpoint before Phase 7** per F001/F002-established rhythm — operator walks the deploy with `scripts/diagnose.sh` as the first-line tool.

### T080 — Operator triggers Portainer stack update

**Files:** (none; operational)

**Acceptance:**

**Given** Phases 0–6 are merged to `main` and CI rebuild of the Grafana image has succeeded (new sha tag in GHCR)
**And** T061–T063 are complete (mneme_metrics user provisioned, password in Portainer env, connectivity verified)
**When** the operator updates the Portainer stack ("Pull and redeploy" with "Re-pull image" enabled)
**Then** all six containers reach `Up` within 5 minutes (NFR-2b carry-over from F001)
**And** no container is in a restart loop — `docker inspect <container> --format '{{.RestartCount}}'` returns `0` for all six containers within the first 5 minutes post-deploy. (More reliable signal than uptime inference: a slow restart loop where containers cycle every 70s would pass an uptime-only check but reveal itself in the restart counter.)
**And** `docker logs` for each new/changed service (postgres-exporter, prometheus, grafana) shows no repeated errors

### T081 — Walk Spec scenarios 1–7

**Files:** (none; operational, results recorded)

**Acceptance:**

**Given** the stack is deployed (T080)
**When** the operator walks `spec.md` §User Scenarios 1 through 7
**Then** each scenario passes exactly as written:
  - 1: First deploy succeeds (sixth container running; mem_limit sum = 600M)
  - 2: Postgres metrics user provisioning was completed (T061-T063 already done; verify here that postgres_exporter is connected via `pg_up == 1`)
  - 3: All three Mneme scrape jobs UP at `/targets`; durations within bounds
  - 4: `honor_labels: true` preserves Mneme's `instance="DS224plus:3000"` (verify via Prometheus `/graph` querying `db_up` and inspecting labels)
  - 5: API dashboard renders with real data
  - 6: Worker dashboard renders with real data
  - 7: Database dashboard renders with real data
**And** any failures are documented with specific symptoms; `scripts/diagnose.sh` is the first-line debugging tool
**And** the dashboard rendering verifications use the actual NAS browser experience (not just API search), confirming visual layout

### T082 — Walk Spec scenarios 8–11

**Files:** (none; operational, results recorded)

**Acceptance:**

**Given** scenarios 1–7 pass (T081)
**When** the operator walks scenarios 8 through 11
**Then** each passes:
  - 8: F002 dashboards still render in their new subfolder locations (regression check)
  - 9: Memory budget — `docker stats --no-stream` shows total observed below 70% of cap; cAdvisor's reduced 60M cap holds
  - 10: Strip script removes the four export-environment keys when piped a Grafana JSON export (functional verification)
  - 11: Cross-repo verification gate (T057 + T058) was passed before merge — recorded in PR description
**And** Success Criteria 1–9 from `spec.md` are all checked
**And** the stack has been running continuously for at least 30 minutes by the end of this task (prerequisite for Phase 8's stability observation)

---

---

## Pre-Phase 8: Retrospective Stub

F002's pattern was to draft the retrospective at code-complete and expand with observation results post-24h. T085 makes that visible as a numbered task between deploy verification (Phase 7) and stability observation (Phase 8) so the post-observation step (filling in T083 + T084 outcomes) doesn't get forgotten.

T085 is numerically last because of the cross-reference stability convention noted in the Overview, but it executes here — between T082 (Phase 7 close) and T083 (Phase 8 start).

### T085 — Draft F003 retrospective stub

**Files:** `specs/003-mneme-app-scraping/retrospective.md`

**Acceptance:**

**Given** T082 has completed (F003 deploy + acceptance scenarios all passed)
**When** the retrospective stub is drafted before Phase 8's 24-hour observation window starts
**Then** the structure mirrors F001 / F002 retrospectives: Outcome / What shipped / Phase 7 fix-chain / What went well / What went poorly / Carry-over to F004 / Memory system state at close / NFR observation outcomes (T055-T056-equivalent — to be filled in post-T083 + T084)
**And** the NFR observation sections are explicit stubs (e.g., "T083 — TBD pending 24h observation"; "T084 — TBD pending 24h observation") rather than absent
**And** the Discipline Notes section explicitly references F002's lesson: "honor the 24h discipline even when 6h looks clean — diurnal patterns (Hyper Backup, scheduled jobs, day/night usage variance for a PKM tool) need a full window to surface, and Mneme + postgres_exporter are net-new behaviors here, not characterized at production scale"
**And** the retrospective is committed but the Status line stays as "Code complete; T083 + T084 pending" until Phase 8 closes — same Status pattern F001 / F002 used during their observation windows

---

## Phase 8: Stability Observation

The 24-hour discipline matching F002. Two NFRs validated. **Both T083 and T084 are observation-only** — anomalies generate follow-up issues, do not block F003 close. (Mirrors F001 T028 / F002 T056 pattern: the observation phase reports, the close-out commit decides whether anomalies block.)

### T083 — NFR-15 stable scrape duration over 24h

**Files:** (none; observational, results recorded in retrospective)

**Acceptance:**

**Given** the stack has run continuously for at least 24 hours post-T082
**When** the operator opens Stack Health → Scrape Duration panel and inspects last 24h for the three new jobs (mneme-api, mneme-worker, mneme-postgres)
**Then** mneme-api line is stable below 1s (NFR-15 target; lightweight prom-client serialization)
**And** mneme-worker line is stable below 1s (NFR-15 target)
**And** mneme-postgres line is stable below 2s (NFR-15 target; postgres_exporter SQL queries)
**And** none of the three lines show upward drift over the 24h window (drift = leak indicator)
**And** F002's existing four jobs (prometheus, node_exporter, cadvisor, synology) remain stable (no regression from F003's wiring)

### T084 — NFR-13 memory budget post-rebalance over 24h

**Files:** (none; observational, results recorded in retrospective)

**Acceptance:**

**Given** the stack has run for ≥ 24 hours (post-T082)
**When** the operator runs `docker stats --no-stream` over a 10-minute window and records peak observed memory per service
**Then** every service's observed memory ≤ its declared `mem_limit` (cAdvisor's 60M cap holds; node_exporter's 30M holds; postgres_exporter under 50M)
**And** the sum of observed memory ≤ 70% of the 600M cap (NFR-13 soft warning threshold; F002 baseline was 42%; F003 projection 47%)
**And** if any service is at or over its `mem_limit`, the failure is the F003-equivalent of F002's T027 trigger — investigate before raising the limit. Per Spec D5 + Plan cross-reference: trims target grafana or node_exporter first, NOT cAdvisor (which is now protected at 50% headroom)
**And** F002's stable-pattern services (Prometheus ~102M, Grafana ~85M, snmp_exporter ~30M) hold their previous observed values within 10% (no regression)

---

## Parallel Execution Guide

Tasks marked `[P]` within the same phase can run concurrently. Dependency flow:

```
T057, T058 (Mneme T013 verification) ─┐
T059 (Mneme /metrics smoke-test)      ├─► T075 (gate for Phase 6)
                                       │
T060 ──► T061 ──► T062 ──► T063 (Phase 1: provisioning)
                                       │
T064 (Phase 2: strip script — needed by Phase 6) ───┐
                                                     │
T065 ──► T066, T067 ──► T068 (Phase 3: subfolder migration; T068 validates)
                                                     │
T069, T070, T071, T072 ──► T073 ──► T074 (Phase 4: wiring)
                                                     │
T075 (Phase 5 gate) ─────────────────────────────────┤
                                                     │
                                              T076 [P], T077 [P], T078 [P] ──► T079
                                                     │
            (merge to main + CI rebuild + Portainer redeploy)
                                                     │
                                              T080 ──► T081 ──► T082
                                                     │
                                              T085 (retrospective stub — between T082 and T083 in execution order)
                                                     │
                                              T083, T084 (24h observation, both observational)
```

3 parallelizable tasks (T076–T078, the dashboard authoring), same shape as F002's Phase 6.

---

## Recommended Execution Rhythm for `/implement`

Phase 0 + Phases 1–6 are largely artifact work (commits to the repo) with three operator-driven sub-phases (Phase 1's T061–T063, Phase 5's T075). Phases 7–8 are operator-driven entirely. Three checkpoints are load-bearing:

- **Phase 0 cross-repo gate.** If T057/T058 reveal that Mneme's T013 hasn't landed (or has divergent language), F003 PR cannot merge. Phases 1–5 can proceed; Phase 6 is blocked. The gate is the F003-unique discipline that prevents shipping Architecture B without its consumer-side documentation.
- **Phase 5 traceability gate (T075).** Same shape as F002's T041. Dashboard authoring depends on the postgres_exporter v0.16.0 metric-name confirmation. Skipping or rushing risks the "no data for three months" anti-pattern.
- **Pre-Phase 7 deploy walk.** Operator-driven. `scripts/diagnose.sh` is the first-line tool. F001 retrospective established this pattern; F002 confirmed it; F003 follows.

Other phase boundaries are review-only.

---

## Out of Scope for this Feature

These are explicitly deferred and must not be pulled in here:

- Alertmanager, alert rule files (Mneme or otherwise), email delivery → dedicated alerting feature
- Cross-repo dashboard sync mechanism → explicitly deleted by Constitution v1.2
- Nightly Grafana-image-rebuild schedule → v1.2-deleted with the cross-repo sync rationale
- Mneme application-side changes → Mneme F008 T010-T016 are Mneme's parallel work stream; F003 depends only on T001-T009 (deployed) plus T013 (cross-repo gate, FR-43)
- DSM internal Postgres scraping → out of scope; locked-down system infrastructure
- `pg_stat_statements` extension setup → if Mneme enables it, slow-query panels populate; if not, `noValue` config handles cleanly
- Future consumer apps (Pinchflat, Immich, Home Assistant) → F004+ each
- Walkgen replacement of `snmp.yml.template` (F002 retro carry-over) — still deferred per its trigger criteria
- Multi-arch Grafana image (F002 retro carry-over) — still deferred; revisit when native arm64 GHA runners are GA
