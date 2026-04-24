# Tasks: Synology NAS Scraping & Dashboards

**Feature Branch:** `002-synology-nas-scraping`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

28 tasks organized into 8 phases, numbered T029–T056 (continuing F001's sequence). Tasks marked `[P]` can be run in parallel with other `[P]` tasks in the same phase.

Phase ordering is deliberately flipped from F001: **operational tooling (diagnose.sh, GHA Node.js 24 migration) lands FIRST**, before any SNMP work, so `diagnose.sh` is available as a debugging tool during F002's own Phase 7 deploy. This inverts F001's historical pain of "most issues surfaced in Phase 7 without baseline tooling."

Phase 8 is an observation-only pass; like F001's T027, it's called a pass based on stability over the 24-hour window rather than on arbitrary measurement.

**Total:** 28 tasks (T040 is a gate — Phase 6 cannot start until it completes; T056 and T055 are both observation-only)
**Parallelizable:** 3 marked `[P]`

---

## Phase 1: Operational Tooling First

### T029 — Author `scripts/diagnose.sh` with container states and service logs sections

**Files:** `scripts/diagnose.sh`

**Acceptance:**

**Given** no diagnose script exists
**When** `scripts/diagnose.sh` is authored
**Then** the script begins with `#!/bin/bash`, `set -euo pipefail`, and defines a `SERVICES` array listing `prometheus grafana cadvisor node-exporter snmp-exporter`
**And** section 1 ("Container states") outputs a table with columns Name / State / Image / Uptime, derived from `docker ps -a --filter` for each service
**And** section 2 ("Recent logs") outputs the last 20 lines of `docker logs` for each service, clearly delimited by `--- <service-name> ---` headers
**And** both sections handle partial-stack states gracefully (missing container reports "not deployed" rather than erroring)

### T030 — Extend `diagnose.sh` with stats, bind-mount ownership (incl. SNMP special-case), port checks

**Files:** `scripts/diagnose.sh`

**Acceptance:**

**Given** T029's sections are in place
**When** sections 3–5 are added
**Then** section 3 outputs `docker stats --no-stream` filtered to the five stack services
**And** section 4 lists bind mount paths under `/volume1/docker/observability/` with their owner and mode from `ls -lnd`
**And** section 4 treats "`snmp_exporter/snmp.yml` MISSING + `.community` MISSING" as a distinguishable state with an actionable summary line per `plan.md` §Operational Tooling
**And** section 5 checks `ss -tlnp` for each port declared in `docs/ports.md` (3030, 8081, 9090, 9100, 9116) and reports which service is bound there vs. expected
**And** each section is wrapped in a function so one section's failure doesn't abort later ones

### T031 — Add exit codes, TTY color handling, and executable bit to `diagnose.sh`

**Files:** `scripts/diagnose.sh`

**Acceptance:**

**Given** sections 1–5 are in place
**When** the final polish is applied
**Then** the script exits `0` if all expected services are `Up` and healthy, `1` if any is restarting/exited, `2` if Docker isn't running or state cannot be determined
**And** if stdout is a TTY (`[ -t 1 ]`), section-status tokens render with red/yellow/green color codes; otherwise they render as plain `OK` / `WARN` / `ERR` suffixes
**And** `git ls-files --stage scripts/diagnose.sh` shows mode `100755` (executable bit tracked)
**And** `bash -n scripts/diagnose.sh` passes syntax check
**And** total runtime on a healthy stack is under 10 seconds (NFR-11)

### T032 — Validate `diagnose.sh` against the running F001 stack

**Files:** (none; validation-only)

**Acceptance:**

**Given** the F001 stack is currently deployed and running on the DS224+
**When** the operator runs `sudo bash scripts/diagnose.sh` (via SSH)
**Then** all four F001 services (`prometheus`, `grafana`, `cadvisor`, `node-exporter`) report `Up` and healthy
**And** section 4 shows `snmp-exporter` bind-mount paths as not yet present (expected — F002 hasn't deployed), with the distinguishable "not yet bootstrapped" summary line
**And** section 5 shows port 9116 as unbound (expected)
**And** total output fits a single terminal screen on this healthy case
**And** script exit code is `0` for the four F001 services being healthy (the absence of snmp-exporter paths is an expected pre-F002 state, not a failure)

### T033 — Update GHA workflow to Node.js 24-capable action versions

**Files:** `.github/workflows/build-grafana-image.yml`

**Acceptance:**

**Given** the current workflow pins `actions/checkout@v4`, `docker/setup-buildx-action@v3`, `docker/login-action@v3`, `docker/build-push-action@v6`
**When** the workflow is updated to Node.js 24-capable versions
**Then** each action's pin is bumped to the latest major release documented as Node.js 24-compatible (verify via each action's release notes before merging — tentative targets from `plan.md`: `@v5 / @v4 / @v4 / @v7`)
**And** the workflow's triggers, permissions, build-args, and tags are UNCHANGED (this is a version bump, not a restructure)
**And** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-grafana-image.yml'))"` passes

### T034 — Validate GHA migration on first post-merge run

**Files:** (none; validation-only, requires merge-to-`main`)

**Acceptance:**

**Given** T033's workflow update is merged to `main` via a commit that also touches `docker/grafana/**` or `VERSION` (so the path filter triggers)
**When** the workflow runs
**Then** all steps complete successfully within NFR-12's 5-minute soft target
**And** the "Node.js 20" deprecation annotation from F001 T017 is no longer present. Verify with the refined pattern (the original loose pattern `node.*20.*(deprecat|remov)` catches commit-message content that mentions Node 20 in prose, producing false positives; use the canonical annotation text instead): `gh run view <run-id> --log | grep -iE "Node\.js 20 actions are (deprecated|being removed)" | wc -l` returns `0`. Cross-check: running the same pattern against F001's old run (ID `24891472655`) returns `1`, confirming the pattern correctly catches the historical warning when present.
**And** GHCR receives both `v<semver>` and `sha-<short>` tags per F001's established pattern
**And** `docker pull ghcr.io/mstellaris/nas-observability/grafana:<new-sha-tag>` succeeds (proves publish works)
**And** if this task fails, it is addressed as an immediate hotfix PR before F002 proceeds (operational discipline matches F001 T017)

---

## Phase 2: SNMP Runbook & Walkgen

### T035 — Write `docs/snmp-setup.md` Steps 1–3 and troubleshooting section

**Files:** `docs/snmp-setup.md`

**Acceptance:**

**Given** SNMP has never been enabled on the DS224+
**When** `docs/snmp-setup.md` is written
**Then** Step 1 (DSM enablement) covers Control Panel → Terminal & SNMP → SNMP tab → enable SNMPv2c → set community string → save, with numbered sub-steps
**And** Step 2 (verify reachability) provides the exact command `snmpwalk -v2c -c <community> localhost .1.3.6.1.4.1.6574 | head` with expected output characteristics
**And** Step 3 (store community string) provides the three exact commands: `sudo mkdir -p`, `sudo bash -c 'echo ...'`, `sudo chmod 600`, `sudo chown 1026:100` — matching the inline-recovery snippet from `scripts/init-nas-paths.sh`
**And** a Troubleshooting subsection covers at minimum: community string mismatch, `snmpwalk` timeout, MIB parse errors during walkgen, fallback to community `snmp.yml` per spec D2

### T036 — Write `docs/snmp-setup.md` Steps 4–6 and update `docs/setup.md` cross-reference

**Files:** `docs/snmp-setup.md`, `docs/setup.md`

**Acceptance:**

**Given** Steps 1–3 of `docs/snmp-setup.md` are written
**When** the remaining steps and cross-references land
**Then** Step 4 (optional walkgen for forks) documents the `snmp_exporter generator` invocation with the `--fail-on-parse-errors` flag and an MIB-files path verification
**And** Step 5 (re-run init script) shows the `curl | sudo bash` command with the expected output including the new `snmp_exporter/snmp.yml` and `.community` lines
**And** Step 6 (redeploy in Portainer) is a short pointer to "Update the stack → Re-pull image → deploy" matching F001's flow
**And** `docs/setup.md` gets a one-paragraph cross-reference under its "What F001 does not ship" section pointing readers at `docs/snmp-setup.md` for F002's SNMP steps
**And** anchor links between docs work (GitHub's rendering preview is the smoke test)

### T037 — Operator enables SNMP and populates `.community` on the DS224+

**Files:** (none; operational — NAS-side configuration only)

**Acceptance:**

**Given** `docs/snmp-setup.md` is committed to `main` and reachable at the repo's raw URL
**When** the operator follows Steps 1–3 on the DS224+
**Then** DSM's SNMP page shows SNMPv2c enabled with the chosen community string saved
**And** `snmpwalk -v2c -c <community> localhost .1.3.6.1.4.1.6574 | head` on the NAS returns Synology OID output (not an auth error, not a timeout)
**And** `/volume1/docker/observability/snmp_exporter/.community` exists with mode 600, owned 1026:100, containing the community string on a single line (`cat .community` returns the value without trailing whitespace other than a final newline)
**And** `sudo bash scripts/diagnose.sh` on the NAS now reports `.community` as present in section 4, but `snmp.yml` is still MISSING (expected — Phase 3 renders it)

### T038 — Operator runs walkgen and commits `snmp.yml.template`

**Files:** `config/snmp_exporter/snmp.yml.template`

**Acceptance:**

**Given** SNMP is enabled (T037) and the walkgen procedure from `docs/snmp-setup.md` §Step 4 is documented
**When** the operator runs the walkgen against the DS224+
**Then** walkgen produces an `snmp.yml.raw` output file with the Synology MIB module populated
**And** post-walk review per `plan.md` §Walkgen is applied: OIDs not consumed by dashboards are pruned, v3-only auth fields (`security_level`, `auth_protocol`, `priv_protocol`) are stripped if present, the `community:` literal is templatized to `${SYNOLOGY_SNMP_COMMUNITY}`
**And** the result is committed as `config/snmp_exporter/snmp.yml.template` with `version: 2` and no v3 noise in the `auths` block
**And** if walkgen fails or is blocked by MIB tooling, the spec D2 fallback is applied: a community `snmp.yml` (wozniakpawel or RedEchidnaUK) is templatized and committed with a `TODO: replace with walkgen output` comment at the top, and a follow-up issue is opened

---

## Phase 3: D3 Scrape-Timing Validation

### T039 — Time 5 scrape cycles locally on the NAS; record observed walk duration

**Files:** (none; measurement-only, documented in the PR description)

**Acceptance:**

**Given** `snmp.yml.template` is committed and `.community` is present on the NAS
**When** the operator runs the validation procedure from `plan.md` §D3 (envsubst the template locally, start snmp-exporter as a detached container, time `curl http://localhost:9116/snmp?target=localhost&module=synology` 5 times 15 seconds apart)
**Then** the 5 observed walk durations are recorded
**And** the 5-sample max is computed
**And** both the full sample set and the max are included in the PR description (format: `walks: 2.1s, 2.4s, 2.2s, 3.1s, 2.3s; max: 3.1s`)
**And** the temporary snmp-exporter container is cleaned up after measurement (`docker rm -f`)

### T040 — Apply D3 interpretation thresholds; adjust scrape_timeout or prune OIDs

**Files:** `config/prometheus/prometheus.yml` (pending; edited in T043), `config/snmp_exporter/snmp.yml.template` (conditional)

**Acceptance:**

**Given** T039 recorded an observed walk duration max
**When** the operator applies the 4-tier threshold table from `plan.md` §D3
**Then** if max < 3s: note in PR description "tightening scrape_timeout to 10s" and adjust T043's scrape job config accordingly
**And** if max 3–10s: keep scrape_timeout at 30s (the plan default); record "within expected range, keeping 30s"
**And** if max 10–25s: keep 30s but review `snmp.yml.template` for over-broad OID walks; prune where possible and re-measure (this may recurse back to T039 for a second measurement)
**And** if max > 25s: prune OIDs mandatorily before continuing — committing a 60s-interval job with a walk approaching the 30s timeout invites cascading failures; update `snmp.yml.template` and re-measure
**And** the final chosen `scrape_timeout` is recorded BOTH in the PR description (with tier-match reasoning) AND as a one-line update to `plan.md` §D3, appended after the threshold table in the format: `**Measured:** max <X>s / chosen scrape_timeout: <Y>s / tier: <which>`. T043 reads the value from `plan.md`, not PR archaeology.

---

## Phase 4: D4 Traceability Table Completion (Gate for Phase 6)

### T041 — Fill in walkgen-line-# column for all planned panels; drop panels without confirmed OID

**Files:** `specs/002-synology-nas-scraping/plan.md` (update the §D4 table)

**Acceptance:**

**Given** `snmp.yml.template` is committed and contains the final walked OID set
**When** each of the ~18 panels in `plan.md` §D4's traceability table is cross-referenced against `snmp.yml.template`
**Then** every panel's OID column is verified against an actual OID in the template, and the "Walkgen line #" column is populated with the line in `snmp.yml.template` where the metric is defined
**And** any panel whose target OID is NOT found in the template is DROPPED from the plan (not shipped with the intention of "no data" — this is the anti-pattern defense)
**And** the revised traceability table is committed to `plan.md` with any drops explained in a brief note below the table
**And** a final total panel count across the three dashboards is reported (starting target: ~18; expect some pruning)

**Gate:** Phase 6 (dashboard authoring) does NOT begin until this task is complete. A dashboard authored against an OID not in walkgen output produces silent "no data" panels that rot for months.

---

## Phase 5: Stack Wiring

### T042 — Add `snmp-exporter` service to `docker-compose.yml`

**Files:** `docker-compose.yml`

**Acceptance:**

**Given** F001's four services are declared in compose
**When** the `snmp-exporter` service is added
**Then** it uses `image: prom/snmp-exporter:v0.28.0` (verify tag exists at implementation time via `docker manifest inspect`)
**And** it declares `container_name: snmp-exporter`, `network_mode: host`, `restart: unless-stopped`, `mem_limit: 40M`, `user: "1026:100"`
**And** its `volumes:` binds `/volume1/docker/observability/snmp_exporter/snmp.yml:/etc/snmp_exporter/snmp.yml:ro`
**And** a healthcheck overrides the default to probe `http://localhost:9116/-/ready` (matching F001's cAdvisor pattern for services with `--port`-adjacent quirks)
**And** `docker compose config` (with a minimal `.env`) parses cleanly

### T043 — Add `synology` scrape job to `config/prometheus/prometheus.yml`

**Files:** `config/prometheus/prometheus.yml`

**Acceptance:**

**Given** the existing three scrape jobs and T040's finalized `scrape_timeout`
**When** the `synology` scrape job is added
**Then** the job declares `job_name: synology`, the `scrape_interval` and `scrape_timeout` from T040, `metrics_path: /snmp`, `params: module: [synology]`, and the idiomatic snmp-exporter relabel config from `plan.md` §Prometheus scrape job
**And** `static_configs.targets` is `['localhost']` (the exporter does the real work; relabel rewrites `__address__` to `localhost:9116`)
**And** F001's existing three scrape jobs (prometheus, node_exporter, cadvisor) are UNCHANGED

### T044 — Extend `init-nas-paths.sh` for snmp_exporter paths and `.community` verification

**Files:** `scripts/init-nas-paths.sh`

**Acceptance:**

**Given** the F001 init script creates prometheus and grafana paths
**When** the script is extended
**Then** a new section creates `/volume1/docker/observability/snmp_exporter/` if not present
**And** the script verifies `.community` exists and is non-empty; if not, emits the **inline recovery snippet** from `plan.md` §Community string handling (full `sudo mkdir → echo → chmod 600 → chown 1026:100` commands) and exits non-zero
**And** the script directs the operator to `docs/snmp-setup.md` §Step 3 for context but does NOT require the operator to navigate there to fix the common case

### T045 — Extend `init-nas-paths.sh` with `envsubst` rendering of `snmp.yml.template`

**Files:** `scripts/init-nas-paths.sh`

**Acceptance:**

**Given** T044's `.community` verification passes
**When** the rendering step runs
**Then** the script curls `snmp.yml.template` from the repo's raw URL to a tempfile
**And** exports `SYNOLOGY_SNMP_COMMUNITY=$(cat /volume1/docker/observability/snmp_exporter/.community)`
**And** runs `envsubst < <template> > /volume1/docker/observability/snmp_exporter/snmp.yml`
**And** chowns the rendered file 1026:100 and chmods 644
**And** echoes a confirmation line matching the existing output pattern (`  /volume1/.../snmp.yml  (owner 1026:100, mode 644)`)
**And** re-running the script is idempotent (re-rendering with the same inputs produces byte-identical output)

### T046 — Update `docs/ports.md`, `.env.example`, `.gitignore`, `docs/deploy.md`

**Files:** `docs/ports.md`, `.env.example`, `.gitignore`, `docs/deploy.md`

**Acceptance:**

**Given** F001's ports.md reserved 9116 for SNMP exporter in F002
**When** the supporting doc + config updates land
**Then** `docs/ports.md` moves `9116` from "Reserved for later" to "Current assignments" with F002 as the claiming feature
**And** `.env.example` gains `# SYNOLOGY_SNMP_COMMUNITY is stored in /volume1/docker/observability/snmp_exporter/.community on the NAS, not in .env` as a comment (no actual key — the tripwire is the file, not the env var)
**And** `.gitignore` adds `*.community` as belt-and-suspenders against the secret ever being committed from a local clone
**And** `docs/deploy.md` gains a new "Updating `snmp.yml`" flow section mirroring the existing "Updating `prometheus.yml`" section

### T047 — Validate compose parses, budget sums to 600M, no `:latest` slipped in

**Files:** (none; validation-only)

**Acceptance:**

**Given** T042–T046 are committed
**When** `docker compose config` is run against the updated compose
**Then** the command exits 0
**And** the sum of `mem_limit` across all five services is exactly 600M (280+140+90+50+40 — constitutional cap hit precisely)
**And** no service references `:latest` (grep test returns 0 matches outside comments)
**And** all five services have `network_mode: host` (grep test returns 5 matches)
**And** `snmp-exporter` service has `user: 1026:100` (greppable for post-F001 services that need it)

---

## Phase 6: NAS Dashboards

**Gate:** T041 (traceability table) MUST be complete before any task in this phase begins.

### T048 [P] — Author NAS Overview dashboard JSON

**Files:** `docker/grafana/dashboards/nas-overview.json`

**Acceptance:**

**Given** the traceability table confirms which panels this dashboard can ship
**When** the dashboard is authored in a local Grafana (editable: true, test Prometheus pointed at the NAS) and exported
**Then** the final JSON matches `plan.md` §NAS Overview composition: 3 rows, 7 panels (4 stat + 2 time series + 1 load-average time series), schemaVersion ≥ 39 for Grafana 11.4
**And** `uid: "nas-overview"`, `title: "NAS Observability — Overview"`, `tags: ["synology", "overview"]` (per `plan.md` §Dashboard tag convention — Tier 1 + Tier 2)
**And** every panel target declares `datasource.uid: "prometheus"` (v1.1 Platform Constraint)
**And** `editable: false` at the dashboard level (F001 lockdown pattern)
**And** `python3 -m json.tool nas-overview.json` passes (valid JSON)
**And** every PromQL query traces to a metric in `snmp.yml.template` per the updated traceability table

### T049 [P] — Author Storage & Volumes dashboard JSON

**Files:** `docker/grafana/dashboards/storage-volumes.json`

**Acceptance:**

**Given** the traceability table confirms which panels this dashboard can ship
**When** the dashboard is authored and exported
**Then** the final JSON matches `plan.md` §Storage & Volumes composition: 4 rows, 5 panels (per-volume gauges, SMART health stats, IOPS time series, pool status)
**And** `uid: "storage-volumes"`, `title: "NAS Observability — Storage & Volumes"`, `tags: ["synology", "storage"]`
**And** panel queries using label matching (e.g., per-volume, per-disk) use the label names produced by walkgen (verify against `snmp.yml.template`)
**And** the same datasource.uid, editable:false, JSON-valid checks from T048 apply

### T050 [P] — Author Network & Temperature dashboard JSON

**Files:** `docker/grafana/dashboards/network-temperature.json`

**Acceptance:**

**Given** the traceability table confirms which panels this dashboard can ship
**When** the dashboard is authored and exported
**Then** the final JSON matches `plan.md` §Network & Temperature composition: 4 rows, 6 panels (interface throughput, per-disk temp stats + time series, system temp + fan)
**And** the fan-speed panel is DROPPED (not shipped empty) if walkgen didn't confirm a fan-speed OID on DS224+
**And** `uid: "network-temperature"`, `title: "NAS Observability — Network & Temperature"`, `tags: ["synology", "network"]`
**And** the same datasource.uid, editable:false, JSON-valid checks from T048 apply

### T051 — Local Grafana image build test confirms all four dashboards visible

**Files:** (none; validation-only — mirrors F001 T014)

**Acceptance:**

**Given** T048–T050 committed the three new dashboard JSONs alongside F001's `stack-health.json`, and the `dashboards.yaml` provisioning path remains `/etc/grafana/dashboards/` (flat, non-recursive — matches FR-20's spec)
**When** `docker build --build-arg VERSION=<current> --build-arg GIT_SHA=<short> -t nas-observability-grafana:local docker/grafana/` runs locally
**Then** the build completes successfully
**And** `docker run --rm --entrypoint cat nas-observability-grafana:local /etc/grafana/dashboards/` via `ls` shows four JSON files (`stack-health.json`, `nas-overview.json`, `storage-volumes.json`, `network-temperature.json`)
**And** running the image locally with an empty bind-mount at `/var/lib/grafana` (simulating production), then `curl -u admin:testpw 'http://localhost:3032/api/search?tag=synology'` returns three dashboards
**And** `curl -u admin:testpw 'http://localhost:3032/api/search?tag=stack-health'` still returns F001's dashboard (regression check — F001 untouched)

---

## Phase 7: DS224+ Deploy & Acceptance

**Pause checkpoint before Phase 7 per F001-established rhythm — operator walks the deploy rather than Claude Code attempting NAS-side operations.**

### T052 — Re-run init script on the NAS; verify SNMP exporter bootstrap

**Files:** (none; operational)

**Acceptance:**

**Given** T042–T047 and T048–T051 are merged to `main` and the CI rebuild of the Grafana image has succeeded
**When** the operator re-runs `init-nas-paths.sh` over SSH on the NAS
**Then** output includes the three F001 lines plus two new lines: `/volume1/docker/observability/snmp_exporter/` (dir) and `/volume1/docker/observability/snmp_exporter/snmp.yml  (owner 1026:100, mode 644)`
**And** `ls -lnd /volume1/docker/observability/snmp_exporter/snmp.yml` shows mode 0644, owner 1026:100
**And** `diff -q /volume1/docker/observability/snmp_exporter/snmp.yml <(envsubst < /tmp/snmp.yml.template)` returns no differences (rendering is exact)
**And** the `.community` file is left untouched by the re-run (root-owned, mode 600, content unchanged)

### T053 — Redeploy stack in Portainer; walk acceptance scenarios 2–7

**Files:** (none; operational)

**Acceptance:**

**Given** T052 completes cleanly
**When** the operator updates the Portainer stack (Pull and redeploy, Re-pull image enabled) and waits for all five containers to reach `Up`
**Then** `spec.md` Scenario 2 passes (fifth container `snmp-exporter` running, `docker inspect` shows `User: 1026:100`, F001 services all still `Up`)
**And** Scenario 3 passes (Prometheus `/targets` shows `synology` job UP with scrape duration below the T040 timeout)
**And** Scenarios 4, 5, 6 pass (NAS Overview, Storage & Volumes, Network & Temperature render with real data within 3 seconds of opening — NFR-8)
**And** Scenario 7 passes (`docker stats --no-stream` confirms snmp-exporter within 40M `mem_limit` and sum across all five services is 600M)
**And** any scenario failures are investigated using `scripts/diagnose.sh` as the first-line tool — this task validates F002's own debugging posture

### T054 — Run `diagnose.sh` on production stack (Scenario 9 end-to-end)

**Files:** (none; operational)

**Acceptance:**

**Given** the stack is fully deployed and healthy post-T053
**When** the operator runs `sudo bash scripts/diagnose.sh` on the NAS
**Then** output matches `spec.md` Scenario 9's contract: all five services `Up`, section 2 shows clean recent logs per service, section 3 shows realistic memory per service, section 4 shows all bind-mount paths with correct ownership, section 5 shows all five declared ports as listening on expected services
**And** total runtime is under 10 seconds (NFR-11)
**And** exit code is 0 (per T031's contract)
**And** output fits within one terminal screen on this healthy state

---

## Phase 8: Stability Observation

Phase 8 is the only observation-only phase. T055 and T056 are both observational — if either surfaces a regression, that's a finding worth a follow-up PR rather than a blocker for F002 close-out (unless it's severe enough to indicate the stack isn't actually stable).

### T055 — Observe SNMP scrape duration stability over 24 hours (NFR-9)

**Files:** (none; observational)

**Acceptance:**

**Given** the stack has been running continuously for at least 24 hours post-T053
**When** the operator opens the Stack Health dashboard's Scrape Duration panel and inspects the `synology` job's line over the last 24 hours
**Then** the line is stable (flat-ish or lightly jittery, not climbing)
**And** no scrape failures are recorded (Prometheus `/targets` shows the last scrape succeeded)
**And** the 24-hour max duration does not exceed the T040-chosen `scrape_timeout`
**And** the observation is recorded in the F002 retrospective (or the PR description if retrospective is deferred)

### T056 — Observe NAS CPU for no sustained scrape-correlated pattern (NFR-10)

**Files:** (none; observational)

**Acceptance:**

**Given** 24-hour observation from T055 is complete
**When** the operator opens the NAS Overview dashboard's CPU time series panel over the last 24 hours
**Then** no visible sustained CPU elevation pattern correlates with the 60s scrape cadence (SNMP scraping is low-overhead; any visible pattern would indicate a leak or an overbroad walk that slipped through T040)
**And** the NAS's overall CPU baseline is consistent with pre-F002 levels (F001 didn't scrape SNMP, so this is the first time we're loading the SNMP daemon; a modest step-up is fine, a growing-over-time pattern is not)
**And** F002 is marked complete once both T055 and T056 observations pass; findings from either become follow-up issues, not blockers

---

## Parallel Execution Guide

Tasks marked `[P]` within the same phase can be worked on concurrently. Dependency flow:

```
T029 ──► T030 ──► T031 ──► T032 (diagnose.sh pipeline)
T033 ──► T034 (GHA migration — independent of diagnose.sh, can interleave)

T029-T034 ──► T035 ──► T036 (docs)
T036 ──► T037 ──► T038 (operator-driven SNMP enablement + walkgen)

T038 ──► T039 ──► T040 (D3 timing validation)

T038 + T040 ──► T041 (traceability gate)

T041 (gate) ──► T048 [P], T049 [P], T050 [P] ──► T051 (dashboards)

T042 ──► T043 (compose → prometheus config; reads timeout from T040)
T042 ──► T044 ──► T045 (init script extensions in order)
T042 ──► T046 (docs updates parallel to init script extensions)
T042–T046 ──► T047 (validation)

T033 + T047 + T051 ──► (merge to main triggers CI + stack deploy readiness)
(merge) ──► T052 ──► T053 ──► T054 (operator walks deploy)

T054 ──► T055, T056 (24h observation, both observational; either order)
```

3 parallel tasks (T048, T049, T050 in Phase 6), down from F001's 11. F002's work is more sequential than F001's because SNMP config + traceability + dashboards form a strict pipeline.

---

## Recommended Execution Rhythm for `/implement`

Phase 1–6 are pure-artifact work (files committed to the repo). Phases 7–8 require the operator. Three checkpoints are load-bearing:

- **Pause before T041 (traceability gate).** Dashboard authoring depends on the walkgen output being finalized. Skipping or rushing the traceability cross-check is how "no data for three months" bugs ship. This is the direct F002 equivalent of F001's pre-CI build test.
- **Pause before T051 (local build test).** Before pushing the dashboard JSONs to `main` (which triggers CI to rebuild and publish the Grafana image), confirm locally that all four dashboards are visible with an empty bind mount. F001 Phase 4 checkpoint caught two real Dockerfile bugs; this is the F002 equivalent.
- **Pause before Phase 7.** Walk the DS224+ deploy together rather than letting Claude Code attempt NAS-side operations. `scripts/diagnose.sh` is now available as the first-line debugging tool (its whole point was to compress F002's own Phase 7 round trips).

Other phase boundaries are review-only.

---

## Out of Scope for this Feature

These are explicitly deferred to later features and must not be pulled in here:

- Alertmanager, alert rules for NAS-level conditions, SMTP delivery → dedicated alerting feature
- Application scraping and application dashboards (Mneme and later apps) → Feature 003+
- Nightly GHA `schedule:` trigger (deferred from F001; will ship with F003 alongside the consumer-dashboard checkout step it serves)
- UPS monitoring via NUT → future dedicated feature
- Migration to SNMPv3 → future feature if threat model changes
- Multi-arch Grafana image (amd64 + arm64) → revisit when native arm64 GHA runners are GA (spec D6)
- External access to Grafana (reverse proxy + auth) → separate external-access feature
- Any expansion of the 600M RAM cap or 30d retention ceiling (Constitution Principle IV)
