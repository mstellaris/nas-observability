# Tasks: Infrastructure Bootstrap

**Feature Branch:** `001-infrastructure-bootstrap`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

28 tasks organized into the 9 plan phases. Tasks marked `[P]` can be run in parallel with other `[P]` tasks in the same phase (different files, no shared dependencies). Unmarked tasks must be completed in order within their phase.

Phases 1–7 build the artifacts. Phase 8 is the first real deploy to the DS224+; it is the earliest point at which DSM-specific issues (ACL handling, cAdvisor capability grants, residential pull speed) surface. Phase 9 tunes against observed memory usage and closes the loop on NFR-1.

**Total:** 28 tasks (T028 conditional on T027 outcome — may be skipped)
**Parallelizable:** 11 marked `[P]`

---

## Phase 1: Repo Scaffolding

### T001 — Create `VERSION` file and directory skeleton

**Files:** `VERSION`, `config/prometheus/.gitkeep`, `docker/grafana/provisioning/datasources/.gitkeep`, `docker/grafana/provisioning/dashboards/.gitkeep`, `docker/grafana/dashboards/.gitkeep`, `docker/grafana/scripts/.gitkeep`, `scripts/.gitkeep`, `docs/.gitkeep`, `.github/workflows/.gitkeep`

**Acceptance:**

**Given** an empty working tree (beyond the spec-kit files)
**When** the scaffolding is committed
**Then** `VERSION` contains a single line with `0.1.0` (no leading `v`, no trailing newline semantics assumed by CI)
**And** the directory tree from `plan.md` §Project Structure exists with `.gitkeep` placeholders where no real file exists yet
**And** no `.gitkeep` persists in directories that will be populated by subsequent tasks (those are removed when the real file is added)

### T002 [P] — Write `.env.example` for Feature 001

**Files:** `.env.example`

**Acceptance:**

**Given** the repo scaffolding exists
**When** `.env.example` is written
**Then** it contains exactly two keys: `GRAFANA_ADMIN_USER=admin` and `GRAFANA_ADMIN_PASSWORD=changeme`
**And** a top-of-file comment states that the real `.env` is gitignored and MUST override `GRAFANA_ADMIN_PASSWORD` before the first deploy
**And** `.gitignore`'s existing `.env` + `!.env.example` rules cover the file correctly (verified by `git check-ignore .env` returning a match and `git check-ignore .env.example` returning no match)

---

## Phase 2: Compose Skeleton

### T003 — Write `docker-compose.yml` with four services, no configs yet

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** the scaffolding is in place
**When** `docker-compose.yml` is written
**Then** four services are declared: `prometheus`, `grafana`, `cadvisor`, `node-exporter`
**And** every service has `network_mode: host`, `restart: unless-stopped`, and a pinned image tag per `plan.md` §Technical Context
**And** every service has an explicit `mem_limit`: Prometheus 280M, Grafana 140M, cAdvisor 90M, node_exporter 50M
**And** the file uses Compose v2 schema (no `version:` key)
**And** no `command:`, `volumes:`, `environment:`, `devices:`, or `cap_add:` blocks are populated yet — those are added in Phase 3

### T004 — Validate compose file parses and budget sums correctly

**Files:** (none; validation-only)

**Acceptance:**

**Given** `docker-compose.yml` from T003
**When** `docker compose config` is run against it with a minimal `.env` present
**Then** the command exits 0 and emits the expanded configuration
**And** the sum of `mem_limit` values is 560M (leaving 40M reserved for Feature 002 per Spec D2)
**And** no service references `:latest` or an unpinned tag (grep for `:latest` returns no matches)

---

## Phase 3: Service Configuration

### T005 [P] — Write `config/prometheus/prometheus.yml` scrape config

**Files:** `config/prometheus/prometheus.yml`

**Acceptance:**

**Given** `docker-compose.yml` exists with the Prometheus service stub
**When** the scrape config is written
**Then** the file matches the exact shape from `plan.md` §Prometheus: global `scrape_interval: 15s` and `evaluation_interval: 15s`, and three scrape_configs (`prometheus` → `localhost:9090`, `node_exporter` → `localhost:9100`, `cadvisor` → `localhost:8080` with per-job `scrape_interval: 30s`)
**And** targets are `localhost:<port>` (not container names), as required by host networking
**And** `promtool check config config/prometheus/prometheus.yml` passes (if promtool is available locally; otherwise defer to Phase 8 for validation on the NAS)

### T006 — Wire Prometheus service in compose (command, volumes, bind mount)

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** `config/prometheus/prometheus.yml` exists (T005)
**When** the Prometheus service is expanded in `docker-compose.yml`
**Then** `command:` contains the flag set from `plan.md` §Prometheus (`--config.file=...`, `--storage.tsdb.path=/prometheus`, `--storage.tsdb.retention.time=30d`, `--storage.tsdb.retention.size=5GB`, `--web.enable-lifecycle`, `--web.listen-address=:9090`)
**And** `volumes:` binds `./config/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro` and `/volume1/docker/observability/prometheus/data:/prometheus`
**And** `docker compose config` still parses cleanly

### T007 — Wire cAdvisor service in compose (flags, devices, cap_add, volumes)

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** the cAdvisor service stub exists
**When** the service is expanded in `docker-compose.yml`
**Then** `command:` contains exactly: `--port=8080`, `--storage_duration=1m`, `--housekeeping_interval=30s`, `--docker_only=true`, and `--disable_metrics=percpu,sched,tcp,udp,accelerator,hugetlb,referenced_memory,cpu_topology,resctrl`
**And** `devices:` contains `/dev/kmsg:/dev/kmsg` and `cap_add:` contains `SYS_ADMIN` (strictly narrower than `privileged: true` per plan.md)
**And** `volumes:` contains the five read-only host mounts from `plan.md` §cAdvisor (`/:/rootfs:ro`, `/var/run:/var/run:ro`, `/sys:/sys:ro`, `/var/lib/docker/:/var/lib/docker:ro`, `/dev/disk/:/dev/disk:ro`)

### T008 [P] — Wire node_exporter service in compose (flags, volumes)

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** the node_exporter service stub exists
**When** the service is expanded in `docker-compose.yml`
**Then** `command:` contains `--path.rootfs=/host/root`, `--path.procfs=/host/proc`, `--path.sysfs=/host/sys`, and the `--collector.filesystem.mount-points-exclude` regex from `plan.md` §node_exporter
**And** `volumes:` contains `/proc:/host/proc:ro`, `/sys:/host/sys:ro`, `/:/host/root:ro,rslave`
**And** `docker compose config` parses cleanly with the full four-service config

---

## Phase 4: Custom Grafana Image

### T009 [P] — Write Grafana datasource provisioning YAML

**Files:** `docker/grafana/provisioning/datasources/datasources.yaml`

**Acceptance:**

**Given** the Grafana provisioning directory exists
**When** `datasources.yaml` is written
**Then** it matches the shape from `plan.md` §Provisioning files: `apiVersion: 1`, one datasource named `prometheus`, type `prometheus`, `access: proxy`, `url: http://localhost:9090`, `isDefault: true`, `editable: false`
**And** the file has no secrets or environment substitutions — the datasource is fully static

### T010 [P] — Write Grafana dashboard provider config

**Files:** `docker/grafana/provisioning/dashboards/dashboards.yaml`

**Acceptance:**

**Given** the provisioning directory exists
**When** `dashboards.yaml` is written
**Then** it matches `plan.md` §Provisioning files: single provider `default`, `folder: ''`, `type: file`, `disableDeletion: true`, `updateIntervalSeconds: 30`, `allowUiUpdates: false`, `options.path: /var/lib/grafana/dashboards`

### T011 [P] — Author the `Stack Health` dashboard JSON

**Files:** `docker/grafana/dashboards/stack-health.json`

**Acceptance:**

**Given** Grafana provisioning config exists
**When** the `Stack Health` dashboard is authored
**Then** it is valid Grafana dashboard JSON (schema v39+ for Grafana 11) with the six panels from `plan.md` §Stack Health dashboard composition: three UP stat panels, one `prometheus_tsdb_head_series` stat, one scrape-duration time series, one text panel
**And** the text panel contains the literal tokens `{{VERSION}}` and `{{GIT_SHA}}` for later substitution by `inject-build-metadata.sh`
**And** dashboard metadata: title `NAS Observability — Stack Health`, tags `[stack-health, meta]`, default time range `last 6 hours`, auto-refresh `30s`
**And** the dashboard references the `prometheus` datasource (matching the provisioned name)

### T012 [P] — Write `inject-build-metadata.sh` substitution script

**Files:** `docker/grafana/scripts/inject-build-metadata.sh`

**Acceptance:**

**Given** the scripts directory exists
**When** the script is written
**Then** it takes three positional args: `$1=VERSION`, `$2=GIT_SHA`, `$3=<path-to-dashboard-json>`
**And** it replaces `{{VERSION}}` with `$1` and `{{GIT_SHA}}` with `$2` in the target file in place
**And** it uses `set -euo pipefail` and fails fast if the target file is missing or unreadable
**And** running it on a sample file with the two tokens produces output where both tokens are replaced and no other content is modified

### T013 — Write the Grafana `Dockerfile`

**Files:** `docker/grafana/Dockerfile`

**Acceptance:**

**Given** all provisioning files, the dashboard JSON, and the injection script exist
**When** the Dockerfile is written
**Then** it matches the shape in `plan.md` §Dockerfile design: `ARG GRAFANA_VERSION=11.4.0`, `FROM grafana/grafana:${GRAFANA_VERSION}-oss`, `ARG GIT_SHA=dev`, `ARG VERSION=0.0.0`
**And** it `COPY`s provisioning files to `/etc/grafana/provisioning/` and dashboards to `/var/lib/grafana/dashboards/`
**And** it runs `inject-build-metadata.sh` with `${VERSION}` and `${GIT_SHA}` and then deletes the script from the image
**And** it sets OCI labels `org.opencontainers.image.source`, `org.opencontainers.image.version`, `org.opencontainers.image.revision`

### T014 — Local build test for the Grafana image

**Files:** (none; validation-only)

**Acceptance:**

**Given** the Dockerfile, provisioning files, dashboard JSON, and injection script exist
**When** `docker build --build-arg VERSION=0.1.0 --build-arg GIT_SHA=test123 -t nas-observability-grafana:local docker/grafana/` is run
**Then** the build completes successfully
**And** inspecting the built image's dashboard file (`docker run --rm --entrypoint cat nas-observability-grafana:local /var/lib/grafana/dashboards/stack-health.json | grep -E "0\.1\.0|test123"`) confirms both tokens were substituted
**And** `docker inspect nas-observability-grafana:local` shows the OCI labels set to the build-arg values

### T015 — Wire Grafana service in compose

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** the Grafana image builds locally (T014)
**When** the Grafana service is expanded in `docker-compose.yml`
**Then** the image reference is `ghcr.io/<github-owner>/nas-observability/grafana:v0.1.0` (matching `VERSION` and the tag the CI workflow will publish)
**And** `environment:` contains the six `GF_*` variables from `plan.md` §Grafana, with `GF_SECURITY_ADMIN_USER` and `GF_SECURITY_ADMIN_PASSWORD` interpolated from `.env`
**And** `volumes:` binds `/volume1/docker/observability/grafana/data:/var/lib/grafana` (no provisioning mount — provisioning is baked in)
**And** `docker compose config` parses cleanly

**Note:** Between T015 and T017, the compose file references `ghcr.io/<github-owner>/nas-observability/grafana:v0.1.0` which does not yet exist in GHCR. Pulling or deploying the stack will fail until T017 publishes the image. This is expected; T024 (first deploy) is gated on T017 completing.

---

## Phase 5: CI Workflow

### T016 — Write `build-grafana-image.yml` GitHub Actions workflow

**Files:** `.github/workflows/build-grafana-image.yml`

**Acceptance:**

**Given** the custom Grafana image builds locally
**When** the workflow YAML is written
**Then** triggers are `push: branches: [main], paths: [docker/grafana/**, VERSION, .github/workflows/build-grafana-image.yml]` and `workflow_dispatch:` only (no `schedule:` per plan.md — that ships in Feature 003)
**And** the `build-and-push` job has `permissions: contents: read, packages: write`
**And** the job steps match `plan.md` §Job shape: checkout, compute `version` and `sha` outputs from `VERSION` and `git rev-parse --short HEAD`, setup-buildx, GHCR login via `GITHUB_TOKEN`, build-push-action@v6 with `context: docker/grafana`, build args for `VERSION` and `GIT_SHA`, two tags (`v<semver>` and `sha-<short>`), and GHA cache
**And** `latest` is NOT in the tag list; `main` is NOT in the tag list

### T017 — First CI run lands the image in GHCR

**Files:** (none; validation-only — requires a push to `main` or a manual `workflow_dispatch`)

**Acceptance:**

**Given** the workflow YAML is merged to `main`
**When** the workflow runs (either via the triggering push or via `workflow_dispatch`)
**Then** it completes successfully within ~5 minutes (per NFR-6)
**And** two tags appear in GHCR under `ghcr.io/<github-owner>/nas-observability/grafana`: `v0.1.0` and `sha-<short>`
**And** pulling either tag locally (`docker pull ghcr.io/<github-owner>/nas-observability/grafana:v0.1.0`) succeeds
**And** the pulled image's `Stack Health` dashboard has the correct `VERSION`/`GIT_SHA` substituted (verify via `docker run --rm --entrypoint cat ... /var/lib/grafana/dashboards/stack-health.json | grep v0.1.0`)
**And** if the first push fails with permission errors, the operator may need to enable package creation in GitHub org/account settings or grant explicit `packages: write` permissions at the org level.
**And** after the first successful push, set the GHCR package visibility to **public** (via https://github.com/users/<owner>/packages/container/nas-observability%2Fgrafana/settings) for unauthenticated pulls from Portainer. Alternative: configure GHCR auth on the NAS's Docker daemon.

**Operational note:** when the F001 PR merges to main, watch the workflow run immediately rather than walking away. If T017 fails, address as a hotfix PR before declaring F001 complete.

---

## Phase 6: NAS Init Script

### T018 — Write `init-nas-paths.sh` and make it executable

**Files:** `scripts/init-nas-paths.sh`

**Acceptance:**

**Given** the scripts directory exists
**When** the init script is written
**Then** the file matches `plan.md` §Bind-mount init script: `#!/bin/bash` with `set -euo pipefail`, `BASE=/volume1/docker/observability`
**And** it iterates over `prometheus/data` and `grafana/data`, creating each directory (`sudo mkdir -p`), clearing DSM ACLs (`sudo synoacltool -del ... || true`), and chowning to the correct UID:GID (`65534:65534` for Prometheus, `472:472` for Grafana)
**And** the file is committed with executable permissions (`git ls-files --stage scripts/init-nas-paths.sh` shows mode 100755)
**And** a syntax-check via `bash -n scripts/init-nas-paths.sh` passes

---

## Phase 7: Documentation

### T019 [P] — Write `docs/ports.md` as authoritative port allocation table

**Files:** `docs/ports.md`

**Acceptance:**

**Given** the docs directory exists
**When** `docs/ports.md` is written
**Then** it declares the four reserved ranges from `spec.md` §D1 (3000–3099 UI, 8080–8099 container/exporter UIs, 9090–9099 Prometheus, 9100–9199 exporters) with explicit rationale for each
**And** it lists current assignments (Grafana 3030, cAdvisor 8080, Prometheus 9090, node_exporter 9100)
**And** it lists future reservations within the ranges (Alertmanager 9093, SNMP exporter 9116, postgres_exporter 9187)
**And** it lists forbidden ports (80, 443, 5000, 5001, 22) with the DSM services that own them
**And** it states that any PR adding or moving a host port MUST update this file in the same change

### T020 [P] — Write `docs/setup.md` including ACL recovery runbook

**Files:** `docs/setup.md`

**Acceptance:**

**Given** the init script (T018) and the spec's acceptance scenarios exist
**When** `docs/setup.md` is written
**Then** it covers prerequisites (DSM 7.3, Container Manager, Portainer, SSH, `docker` group), the one-time NAS init via `scripts/init-nas-paths.sh`, `.env` population, first Portainer deploy, and verification steps (visit `:9090/targets`, visit `:3030`, confirm dashboard renders)
**And** the troubleshooting section explicitly walks through ACL restart-loop recovery with the exact commands from `plan.md` §docs/setup.md — `synoacltool -del` followed by `chown` with the specific UIDs (65534:65534 Prometheus, 472:472 Grafana) spelled out
**And** the troubleshooting section includes the cAdvisor `SYS_ADMIN`/`/dev/kmsg` rejection fallback: if DSM refuses the capability grant, document the specific error observed and fall back to `privileged: true` in a follow-up PR with that error quoted as justification
**And** the troubleshooting section covers port collision (`ss -tlnp | grep <port>`) and unhealthy Grafana datasource (`docker exec ... wget ... http://localhost:9090/-/healthy`)

### T021 [P] — Write `docs/deploy.md` for Portainer flow

**Files:** `docs/deploy.md`

**Acceptance:**

**Given** the compose file and docs exist
**When** `docs/deploy.md` is written
**Then** it covers three flows: first deploy (reference to setup.md), image update (bump Grafana tag in compose, commit, redeploy with "pull latest image"), and rollback (point tag back to previous `sha-<short>` or `v<prev>`, redeploy)
**And** it restates the compliance checklist for service-adding PRs, or links to the PR template that owns it
**And** it includes an optional "pre-pull images over SSH" note for when residential bandwidth makes cold deploys exceed NFR-2b

### T022 [P] — Write `.github/pull_request_template.md` with compliance checklist

**Files:** `.github/pull_request_template.md`

**Acceptance:**

**Given** the `.github/` directory exists
**When** the PR template is written
**Then** it matches `plan.md` §Compliance Checklist: five checkboxes (pinned image version, explicit `mem_limit`, total budget ≤ 600 MB with arithmetic in PR description, port declared in `docs/ports.md`, bind mount documented if stateful)
**And** it includes the "remove/strike for doc-only or CI-only PRs" instruction
**And** when a new PR is opened against the repo, GitHub pre-fills the description with this checklist

---

## Phase 8: DS224+ Cold Deploy

**Note:** Phase 8 tasks require physical/SSH access to the DS224+. Claude Code prepares the artifacts and runbooks; the operator executes the deploy. Acceptance criteria below describe what passes — the operator walks through the spec's acceptance scenarios and records results.

### T023 — NAS-side one-time init

**Files:** (none; operational)

**Acceptance:**

**Given** the repo is accessible on the NAS (cloned locally or `init-nas-paths.sh` copied via `scp`) and the operator has SSH access with `sudo` available
**When** the operator runs `sudo bash scripts/init-nas-paths.sh` on the NAS
**Then** `/volume1/docker/observability/prometheus/data` and `/volume1/docker/observability/grafana/data` exist
**And** `ls -ln` on each directory shows the correct UID:GID (65534:65534 and 472:472 respectively)
**And** `synoacltool -get <path>` shows no DSM ACL entries remaining

### T024 — First Portainer stack deploy

**Files:** (none; operational)

**Acceptance:**

**Given** the init script has run (T023) and the CI workflow has published `ghcr.io/<github-owner>/nas-observability/grafana:v0.1.0` to GHCR (T017)
**When** the operator creates a new Portainer stack pointing at this repo's `docker-compose.yml` and populates `GRAFANA_ADMIN_USER` and `GRAFANA_ADMIN_PASSWORD` via Portainer's stack environment variables field
**Then** all four containers enter the `running` state within 5 minutes on a cold cache (NFR-2b)
**And** no container is in a restart loop (check via `docker ps` showing uptime > 60s for all four)
**And** `docker logs prometheus` / `grafana` / `cadvisor` / `node-exporter` show no repeated errors

### T025 — Walk through spec acceptance scenarios 1–5

**Files:** (none; operational — results recorded in the PR description or a short follow-up note)

**Acceptance:**

**Given** the stack is deployed (T024)
**When** the operator walks through `spec.md` §User Scenarios 1 through 5 (fresh deploy succeeds, Prometheus scrapes three targets, Grafana loads with provisioned datasource, Stack Health dashboard renders, memory limits enforced)
**Then** each scenario passes exactly as written
**And** any failures are documented with the specific symptom (screenshot, log excerpt, or `docker stats` output) for follow-up
**And** if cAdvisor's `SYS_ADMIN`/`/dev/kmsg` grant was rejected by DSM, the fallback to `privileged: true` is applied in a follow-up PR per T020's guidance

### T026 — Walk through spec acceptance scenarios 6–10

**Files:** (none; operational)

**Acceptance:**

**Given** scenarios 1–5 pass (T025)
**When** the operator walks through `spec.md` §User Scenarios 6 through 10 (retention flags enforced, CI publishes on push, bind-mounted state survives redeploy, port allocation table respected, compliance gates block non-compliant PRs)
**Then** each scenario passes
**And** success criteria 1–9 from `spec.md` §Success Criteria are all checked
**And** the stack has been running continuously for at least 1 hour by the end of this task (prerequisite for T027)

---

## Phase 9: Tuning Pass

Phase 9 is the only conditional phase. T027 is always executed; T028 only runs if T027 observes cAdvisor at or over 90 MB. If T027 passes cleanly, the feature is complete after T027.

### T027 — Verify per-service memory stays within `mem_limit` over 1 hour

**Files:** (none; operational — results recorded)

**Acceptance:**

**Given** the stack has been running for at least 1 hour (post-T026)
**When** the operator runs `docker stats --no-stream` several times over a 10-minute window and records peak observed memory per service
**Then** every service's observed memory is ≤ its `mem_limit` (Prometheus 280M, Grafana 140M, cAdvisor 90M, node_exporter 50M)
**And** the sum of observed memory is ≤ 560M
**And** if cAdvisor is at or over 90M, proceed to T028; otherwise T028 is skipped and the feature is complete

### T028 — Tune cAdvisor flags if it exceeded 90 MB (conditional)

**Files:** `docker-compose.yml` (if changes needed)

**Acceptance:**

**Given** T027 observed cAdvisor at or over 90 MB
**When** the operator tightens cAdvisor flags (candidates: reduce `--storage_duration` further, add more collectors to `--disable_metrics`, or reduce `mem_limit` on another F001 service per `spec.md` §D2 — never expand the 600 MB cap)
**Then** the change is made in a follow-up PR with the compliance checklist satisfied
**And** after redeploy, T027 is re-run and passes
**And** if no flag tuning is sufficient, the fallback (per `spec.md` §D2) is to trim Grafana to 130M or node_exporter to 40M rather than exceeding the cap; this decision is documented in the PR description

---

## Parallel Execution Guide

Tasks marked `[P]` within the same phase can be worked on concurrently. Dependency flow:

```
T001 ──► T002 [P]
T001 ──► T003 ──► T004
T004 ──► T005 [P] ──► T006
     ──► T007
     ──► T008 [P]

T006 + T007 + T008 ──► T009 [P], T010 [P], T011 [P], T012 [P]
T009 + T010 + T011 + T012 ──► T013 ──► T014 ──► T015

T015 ──► T016 ──► T017 (T017 requires merge to main or workflow_dispatch)

T001 ──► T018 (independent of services; can be done any time after scaffolding)

T001 ──► T019 [P], T020 [P], T021 [P], T022 [P]   (docs/PR template independent of code)

T017 + T018 + T020 ──► T023 ──► T024 ──► T025 ──► T026 ──► T027 ──► T028 (conditional)
```

Phase 1–7 tasks are all pure-artifact work (files committed to the repo) and can largely be done by Claude Code without operator intervention. Phase 8–9 require the operator — Claude Code prepares, the operator deploys and reports.

---

## Recommended Execution Rhythm for `/implement`

Run Phases 1–7 sequentially with an operator review at each phase boundary. Two checkpoints are load-bearing and should not be skipped:

- **Pause between Phase 4 and Phase 5** — custom Grafana image done, CI workflow not yet landed. This is the natural checkpoint where Dockerfile bugs, provisioning typos, and dashboard JSON schema mistakes surface via T014's local build test, *before* CI starts pushing broken images to GHCR on every merge. A Dockerfile fix caught here is a pre-merge edit; caught after Phase 5 it's a revert + fix + re-push cycle.
- **Pause before Phase 8** — walk through the DS224+ deploy together rather than letting Claude Code attempt operational tasks. Phase 8 is the first real interaction with DSM, the NAS filesystem, Portainer, and GHCR pulls over residential bandwidth. Claude Code prepares runbooks and verification commands; the operator runs them and reports back.

Other phase boundaries are review-only (quick skim, approve, continue). The two above are different in kind: they're the points where defects compound if not caught.

---

## Out of Scope for this Feature

These are explicitly deferred to later features and must not be pulled in here:

- SNMP exporter, Synology MIBs, NAS-specific dashboards — Feature 002
- Application scraping (Mneme `/metrics`), application dashboards, dashboard-sync CI step, nightly GHA `schedule:` trigger — Feature 003+
- Alertmanager, alert rules, SMTP delivery — dedicated alerting feature
- postgres_exporter — ships with the first Postgres-backed app
- Caddy or any reverse proxy for Grafana — separate external-access feature
- `scripts/check-budget.sh` or any automated compliance check — PR-template-enforced in F001
