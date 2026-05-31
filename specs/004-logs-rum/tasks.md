# Tasks: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

22 tasks across 11 phases (Phase 0 + Phases 1–10), numbered **T086–T107** (continuing F003's T057–T085 sequence). Tasks marked `[P]` can run in parallel with other `[P]` tasks in the same phase.

**Phase 0 is the most consequential task group.** Three of its four verifications *branch the topology of everything downstream* — they are not formalities:
- **T086 (TLS edge / domain)** decides whether the receiver's HTTPS edge is DSM Application Portal (public domain + cert) or Tailscale-TLS / Caddy-direct (domain-less). If domain-less, **Caddy becomes the primary edge**, not a fallback.
- **T087 (Alloy `api_key`)** decides 2-container vs. 3-container topology (native enforcement vs. a Caddy key/CORS proxy) — and the 450M budget split.
- **T089 (socket `stat`)** decides the D8 `group_add` GID vs. the socket-proxy fallback.

Run Phase 0 first and let its outcomes settle the config shape before writing any service config (Phases 2–5).

**Phase 7 (retention-deletion) is deliberately separate from Phase 10 (24h observation).** A 24h window cannot fire a 7-day compactor; Phase 7 proves time-retention deletion via a short-retention test, and installs the operator disk-watch (Loki has no automatic byte-cap — size protection is time-retention + vigilance, stated plainly).

**F004 does NOT block on Mneme F012** (producer ships first, Spec D7). F004 closes on its own synthetic beacon (Phase 6); publishing the contract (Phase 8) is the F012-unparking artifact.

**Total:** 22 tasks (T086–T107).
**Parallelizable:** Phase 0's four checks (T086–T089); the two doc tasks T090/T091.
**Phase 10 (T106) is observation-only:** anomalies generate follow-up issues, do not block F004 close — mirrors F001 T028 / F002 T056 / F003 T083 pattern.
**Note on T107 numbering:** T107 (retrospective stub) is numerically last but executes between T105 (Phase 9 close) and T106 (Phase 10 start). File order reflects execution order.

---

## Phase 0: Pre-flight Gates (F004-unique — topology-branching)

All four are verification-only and can run in parallel `[P]`, but their *outcomes* gate later phases. Capture every result in the PR description.

### T086 — Verify browser→receiver reachability + the TLS edge `[P]`

**Files:** (none; verification-only — outcome recorded in PR + `docs/logs-setup.md`)

**Acceptance:**

**Given** the Faro receiver must be reachable from browsers over HTTPS with a valid cert (Spec FR-51, Plan §D5)
**When** the operator audits the NAS's external-access story
**Then** one of these edges is confirmed and recorded:
  - **(A) DSM Application Portal** — a public domain/subdomain with a DSM-managed cert is available and pointable at `localhost:<receiver-port>`. Default path.
  - **(B) Tailscale-only / domain-less** — no public domain; the edge becomes Tailscale-TLS (MagicDNS + `tailscale cert`) or **Caddy-direct TLS on a high port**, and **Caddy is the primary edge** (not a fallback).
**And** the chosen edge determines T100's implementation and the contract block's endpoint URL (T103)
**And** if (B), this also implies the Caddy path for key/CORS unless T087 shows Alloy can do key+CORS while Caddy does only TLS — record the interaction

### T087 — Verify Alloy `faro.receiver` capability (api_key + CORS) `[P]`

**Files:** (none; verification-only)

**Acceptance:**

**Given** Plan §D5 prefers native Alloy enforcement of `api_key` + `cors_allowed_origins`
**When** the operator checks the pinned Alloy version's `faro.receiver` `server` block reference (and/or a quick local smoke of the config)
**Then** it is confirmed whether `api_key` AND `cors_allowed_origins` are both supported
**And** if **yes** → 2-container topology (Loki + Alloy), budget Loki 200 / Alloy 250 = 450M; Alloy enforces key+CORS
**And** if **no** (api_key absent) → 3-container topology: add a minimal Caddy proxy for key+CORS; rebalance Loki 200 / Alloy 210 / Caddy 40 = 450M; Caddy gets a `docs/ports.md` row (T093/T100)
**And** the outcome is recorded before any `config.alloy` is written (T094/T099)

### T088 — Pin Loki + Alloy image versions `[P]`

**Files:** (none; verification feeds T093/T095 compose)

**Acceptance:**

**Given** F001's lesson that upstream tags occasionally lie
**When** the operator runs `docker manifest inspect grafana/loki:<tag>` and `docker manifest inspect grafana/alloy:<tag>` for the target latest-stable Loki 3.x / Alloy v1.x
**Then** the exact existing tags are confirmed (incl. linux/amd64 platform present) and pinned
**And** the confirmed pins are used verbatim in `docker-compose.logs.yml` (no `:latest`, no floating tags — Principle I)

### T089 — Stat the Docker socket (D8 group_add GID) `[P]`

**Files:** (none; verification feeds T095 compose)

**Acceptance:**

**Given** Alloy must read the root-owned Docker socket while running as `1026:100` (Plan §D8)
**When** the operator runs `stat -c '%U:%G %a' /var/run/docker.sock` on the DS224+
**Then** the owner:group:mode is recorded (expected `root:root 660`)
**And** the GID to `group_add` is determined (e.g. `"0"` for a `root:root 660` socket)
**And** if the bare `group_add` is judged too broad or insufficient, the socket-proxy sidecar fallback (Plan §D8) is selected instead (Alloy → `tcp://localhost:<port>`, +~20M, rebalance Alloy 230 / proxy 20)

---

## Phase 1: Bind-mount Paths + Runbook

Honors the Portainer absolute-path constraint (memory `project_portainer_bind_mounts`) and the DSM ACL recovery (memory `project_dsm_acl_recovery`). T090/T091 are `[P]`.

### T090 — Extend `scripts/init-nas-paths.sh` for Loki + Alloy `[P]`

**Files:** `scripts/init-nas-paths.sh`

**Acceptance:**

**Given** Loki/Alloy state and config must live at absolute host paths under `/volume1` (Portainer constraint)
**When** `init-nas-paths.sh` is extended
**Then** it creates the Loki state dirs (`chunks`, `tsdb-index`, `tsdb-cache`, `compactor`, `rules`) and the Alloy state dir (`data`) under the F001–F003 `/volume1` convention path (confirm exact root at impl)
**And** it `chown -R 1026:100` all created dirs (DSM admin UID; v1.1)
**And** it `curl`s the committed `loki-config.yaml` and `config.alloy` from the repo raw URL to their absolute host paths (the compose mounts those `:ro`)
**And** the script is idempotent / safely re-runnable (same discipline as the existing F001–F003 path setup)

### T091 — Write `docs/logs-setup.md` `[P]`

**Files:** `docs/logs-setup.md`

**Acceptance:**

**Given** the logs/RUM subsystem needs a NAS-side runbook (sister to `docs/snmp-setup.md`, `docs/mneme-setup.md`)
**When** `docs/logs-setup.md` is written
**Then** it covers: (1) bind-mount path pre-creation + `chown 1026:100`; (2) **DSM ACL restart-loop recovery** (`synoacltool -del` + `chown`, memory `project_dsm_acl_recovery`); (3) the TLS-edge setup per T086's chosen path (DSM Application Portal subdomain, or Tailscale/Caddy); (4) API-key generation (`openssl rand -base64 32`) + setting `FARO_API_KEY` / `FARO_ALLOWED_ORIGIN` in Portainer stack env; (5) the operator disk-watch for Loki (disk-usage check — NOT an automatic size cap; lever is shortening retention); (6) pointer to the published contract block
**And** it states plainly that Loki's disk protection is 7-day time retention (automatic) + operator vigilance, not an auto byte-cap

---

## Phase 2: Loki Deploy + Config

### T092 — Author `config/loki/loki-config.yaml`

**Files:** `config/loki/loki-config.yaml`

**Acceptance:**

**Given** Spec D3/D4 + Plan §Loki config
**When** the config is authored
**Then** it sets single-binary mode (`replication_factor: 1`, `kvstore: inmemory`), filesystem object store + TSDB shipper, **schema v13** (`from:` = first-deploy date, `period: 24h`)
**And** `server.http_listen_port: 3100` and `server.grpc_listen_port: 3101` (remapped off upstream 9095)
**And** `limits_config.retention_period: 168h` (7d) AND `compactor.retention_enabled: true` (the line that makes deletion actually fire — default is OFF)
**And** all storage paths are under the `/loki` bind-mount prefix
**And** `auth_enabled: false` (single-tenant, host-firewalled)

### T093 — Add Loki to `docker-compose.logs.yml` + deploy + verify

**Files:** `docker-compose.logs.yml` (NEW), `docs/ports.md`

**Acceptance:**

**Given** T088 pinned the Loki image and T092 authored the config
**When** the `loki` service is added to a new `docker-compose.logs.yml` (`network_mode: host`, `restart: unless-stopped`, `user: "1026:100"`, `mem_limit: 200M`, pinned image, config `:ro` + state `:rw` bind mounts) and deployed as a Portainer stack
**Then** the `loki` container enters `running`; the 6 metrics-subsystem containers are untouched (Scenario 1)
**And** `curl -s http://localhost:3100/ready` returns ready
**And** a manual log push (`POST /loki/api/v1/push`) round-trips and is queryable
**And** `docs/ports.md` moves Loki 3100 (HTTP) + 3101 (gRPC) into Current assignments, range `3100–3199`, feature F004 (FR-54 + compliance gate FR-58)

---

## Phase 3: Alloy Backend-Log Pipeline

### T094 — Author `config/alloy/config.alloy` (backend-log pipelines)

**Files:** `config/alloy/config.alloy`

**Acceptance:**

**Given** T087/T089 settled the receiver topology + socket mechanism, and Plan §Alloy config
**When** pipelines 1+2 are authored
**Then** `discovery.docker` + `discovery.relabel` set the **canonical label `container`** (from `__meta_docker_container_name`) plus `compose_service` — resolving Spec Scenario 2's label-schema question
**And** `loki.source.docker` collects container stdout **via the socket (API-based)** and forwards to `loki.write`
**And** a host-log source (`local.file_match` + `loki.source.file` on `/var/log/*.log`) forwards host logs (best-effort)
**And** `loki.write` points at `http://localhost:3100/loki/api/v1/push` and relies on its default retry/backoff + WAL (no crash-loop if Loki is down — FR-50)
**And** no `/volume1/@docker/containers` mount is referenced (API-based, not file-tailing — Plan §D8)

### T095 — Add Alloy to `docker-compose.logs.yml` + deploy

**Files:** `docker-compose.logs.yml`, `docs/ports.md`

**Acceptance:**

**Given** T089 determined the `group_add` GID (or the socket-proxy fallback)
**When** the `alloy` service is added (`network_mode: host`, `restart: unless-stopped`, `user: "1026:100"`, `group_add: ["<gid>"]`, `mem_limit: 250M`, pinned image, config `:ro` + state `:rw` + Docker socket `:ro` **only**) and deployed
**Then** the `alloy` container enters `running` and reads the Docker socket successfully (no permission errors in logs)
**And** Alloy does NOT crash-loop if Loki is cycled (retries + resumes — FR-50, verified by stopping/starting Loki and watching restart counts stay flat over 10 min)
**And** `docs/ports.md` moves Alloy 3110 (UI) + 3111 (faro.receiver, localhost) into Current assignments (and Caddy 3112 if T087 forced the proxy)

### T096 — Verify container logs in Grafana Explore

**Files:** (none; verification-only)

**Acceptance:**

**Given** Loki + Alloy are running with the Loki datasource not yet added (use Loki's API directly or add the datasource first — see Phase 4 ordering note)
**When** logs are queried in Grafana → Explore → Loki (after T097/T098) or via `logcli`/curl
**Then** Mneme's pino JSON log lines are returned for the Mneme API container, queryable by `{container="<mneme-api-container>"}` (label key `container` per T094; query string illustrative — acceptance is "queryable by container," not a literal label match — Spec Scenario 2)
**And** an all-streams query returns log streams for every running container including the observability stack itself
**And** JSON fields are queryable via `| json` parsing

---

## Phase 4: Grafana Loki Datasource

### T097 — Add Loki datasource to provisioning

**Files:** `docker/grafana/provisioning/datasources/datasources.yaml`

**Acceptance:**

**Given** FR-52 + v1.1 datasource-UID determinism
**When** the Loki datasource is added to the provisioning YAML
**Then** it declares `type: loki`, **`uid: loki`** (explicit), `access: proxy`, `url: http://localhost:3100`
**And** the existing `uid: prometheus` datasource is unchanged

### T098 — Rebuild Grafana image + redeploy + no-regression check

**Files:** (none; CI + deploy — triggered by the T097 change under `docker/grafana/**`)

**Acceptance:**

**Given** T097 changed the baked provisioning
**When** the `build-grafana-image` workflow rebuilds + publishes, and the operator redeploys the metrics stack with the new image
**Then** both datasources (`uid: prometheus`, `uid: loki`) pass Grafana's health check (Scenario 7)
**And** all F001–F003 dashboards render unchanged — no regression from the rebuild (NFR-22, Scenario 7)
**And** the `honor_labels` count-gate (`expected=2`) is unaffected (no `prometheus.yml` change)

---

## Phase 5: Faro Receiver + TLS Edge

### T099 — Add the `faro.receiver` pipeline to `config.alloy`

**Files:** `config/alloy/config.alloy`

**Acceptance:**

**Given** T087 confirmed (or denied) native Alloy key+CORS
**When** the `faro.receiver` pipeline 3 is added
**Then** it binds `127.0.0.1:3111`, sets `cors_allowed_origins = [sys.env("FARO_ALLOWED_ORIGIN")]` (explicit, never `*`) and `api_key = sys.env("FARO_API_KEY")` (if T087 confirmed native support; else this enforcement lives in Caddy per T100)
**And** `output { logs = [loki.write...]; traces = [] }` — **traces output UNWIRED** so trace signals are dropped (FR-49, Scenario 6; the literal in-code APM-deferral seam)
**And** secrets come via `sys.env` (no envsubst/sed templating — sidesteps memory `project_dsm_no_envsubst`)

### T100 — Stand up the TLS edge + wire secrets

**Files:** `.env.example`, `docs/logs-setup.md` (+ `docker-compose.logs.yml` & `docs/ports.md` if Caddy), Portainer stack env (operational)

**Acceptance:**

**Given** T086 chose the edge (DSM Application Portal / Tailscale / Caddy-direct) and T087 chose the enforcement point
**When** the edge is stood up
**Then** TLS terminates at the chosen edge and forwards to the localhost Faro receiver (or to Caddy → receiver)
**And** `FARO_API_KEY` and `FARO_ALLOWED_ORIGIN` are set in Portainer stack env; `.env.example` documents both variable names (values not committed — v1.3 Secrets)
**And** if T087 forced the Caddy path: a minimal Caddy container is added to `docker-compose.logs.yml` (key-check + CORS + proxy to `:3111`), rebalanced ≤ 500M, with its port in `docs/ports.md`
**And** the public endpoint URL is now fixed (feeds T103's contract block)

---

## Phase 6: Synthetic Beacon Verification (F004 proves itself — no F012 dependency)

### T101 — Run the four-assertion synthetic beacon

**Files:** (none; verification — payload + queries captured in PR; optionally a `scripts/` helper)

**Acceptance:**

**Given** the receiver + edge are live (T099/T100) and Loki is ingesting (T093)
**When** a hand-built Faro-format payload (a log + an exception + a measurement + a trace span) is POSTed per Plan §Synthetic beacon
**Then** **(1) key enforced** — POST without/with-wrong `x-api-key` → 401/403; with correct key → 2xx
**And** **(2) CORS enforced** — `OPTIONS` preflight with Mneme's origin → `Access-Control-Allow-Origin: <mneme-origin>`; any other origin → header absent
**And** **(3) traces dropped** — the log/exception/measurement land in Loki; the trace span does NOT; nothing errors (Scenario 6)
**And** **(4) accepted signals land** — a LogQL query returns the log + exception + measurement
**And** this passes using only F004-generated signals — no Mneme telemetry required (Spec D7, FR-57)

---

## Phase 7: Retention-Deletion Verification (SEPARATE from the 24h observation)

### T102 — Short-retention test + install operator disk-watch

**Files:** `config/loki/loki-config.yaml` (temporary toggle), `docs/logs-setup.md` / `scripts/diagnose.sh`

**Acceptance:**

**Given** a 24h window structurally cannot fire a 7-day compactor (Spec §phase-8)
**When** Loki retention is temporarily set to ~1h, logs are ingested, and the compactor's deletion cycle is awaited
**Then** the compactor **deletes** expired chunks/index on schedule (verified via disk inspection + Loki logs) — proving the time-retention deletion mechanism is wired and fires
**And** retention is restored to 168h (7d) afterward
**And** the **operator disk-watch** is installed: a Loki disk-usage check in `docs/logs-setup.md` / `diagnose.sh`, documented explicitly as vigilance (NOT an automatic byte-cap — Loki has none; the lever if disk grows is shortening retention)
**And** `tasks.md` / docs do not imply an automatic hard size cap that doesn't exist

---

## Phase 8: Publish the Faro Contract Block (the F012-unparking artifact)

### T103 — Publish the contract block into Mneme's `docs/observability.md`

**Files:** `/Users/stellar/Code/mneme/docs/observability.md` (cross-repo; coordinated, not a blocking pre-req)

**Acceptance:**

**Given** T100 fixed the public endpoint URL
**When** the Faro contract block (Plan §Faro contract block) is published into Mneme's `docs/observability.md`
**Then** it states the authoritative producer-owned interface: **endpoint URL**, **`x-api-key` header name**, **CORS allowed-origin**, **accepted signals** (logs/exceptions/events/measurements) and **dropped signals** (traces)
**And** the `initializeFaro(...)` snippet is marked **illustrative — exact SDK init verified F012-side** (Faro sets headers via the transport's `requestOptions.headers`, not necessarily a top-level field)
**And** publishing this is recorded as an F004 done-criterion (it unparks F012); F004 does NOT wait for Mneme to consume it (Spec D6/D7)

---

## Phase 9: DS224+ Deploy + Acceptance

### T104 — Update operator-facing docs + `diagnose.sh`

**Files:** `scripts/diagnose.sh`, `README.md`, `docs/deploy.md`, `docs/setup.md`

**Acceptance:**

**Given** the logs/RUM subsystem is a new operational surface
**When** the docs are updated
**Then** `diagnose.sh` is extended to check Loki `/ready`, Alloy health, the two new containers, and Loki disk usage
**And** `README.md` Status section reflects F004 (logs/RUM shipped); the design-constraints already reflect v1.3 (two budgets)
**And** `docs/deploy.md` covers deploying the second (`docker-compose.logs.yml`) stack and the compliance checklist applies the logs/RUM ≤ 500M cap
**And** `docs/setup.md` cross-references `docs/logs-setup.md`

### T105 — Operator acceptance walk-through

**Files:** (none; operational — outcomes in PR)

**Acceptance:**

**Given** both stacks are deployed
**When** the operator walks Spec Scenarios 1–10
**Then** all pass: subsystem deploys without disturbing metrics (1), container logs flow (2), Alloy retries gracefully (3), receiver accepts keyed / rejects unkeyed (4), CORS enforced (5), traces dropped (6), logs visualized alongside metrics (7), retention bounds disk via T102's separate test (8), bind-mount perms survive redeploy (9), F004 closes on its synthetic beacon (10)
**And** `diagnose.sh` is the first-line tool for any misbehavior

---

## Phase 10: 24-Hour Stability Observation (observation-only)

### T106 — 24h observation: ingestion stability + growth rate

**Files:** (none; observation — outcomes in retrospective)

**Acceptance:**

**Given** F002/F003 observation discipline
**When** the subsystem runs for 24 hours under real container-log load
**Then** **ingestion stability** is characterized: Alloy keeps up, the Faro receiver stays responsive, no crash-loop, observed logs/RUM memory stays well under the 500M cap (NFR-18)
**And** the **disk-growth rate** is measured and extrapolated ("will 7 days of logs fit under the operator disk-watch threshold?")
**And** it is recorded that this window does **NOT** characterize retention-deletion (T102 owns that — a 7-day compactor can't fire in 24h)
**And** anomalies generate follow-up issues; they do not block F004 close (mirrors F001 T028 / F002 T056 / F003 T083)

### T107 — Retrospective stub

**Files:** `specs/004-logs-rum/retrospective.md`

**Acceptance:**

**Given** F004 is code-complete and through its acceptance walk-through (executes between T105 and T106)
**When** the retrospective stub is created
**Then** it captures stack state post-F004 (8 containers across two stacks: 6 metrics + Loki + Alloy [+ Caddy/proxy if a fallback fired]), the two-subsystem budget actuals, and placeholders for the 24h observation outcomes (T106)
**And** it notes any Phase-0 branch taken (Caddy edge/proxy, socket-proxy) as a deviation from the 2-container default, with rationale
**And** it carries forward any deferrals (curated logs/RUM dashboards, logs/RUM alerting, APM/Tempo) with revisit criteria
**And** it records the cross-repo handoff: contract published (T103) → Mneme F012 unparked; real end-to-end verification is F012's Phase 2 gate, not F004's
