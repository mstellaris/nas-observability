# Tasks: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

22 tasks across 11 phases (Phase 0 + Phases 1–10), numbered **T086–T107** (continuing F003's T057–T085 sequence). Tasks marked `[P]` can run in parallel with other `[P]` tasks in the same phase.

**Phase 0 (the most consequential task group) is COMPLETE — all four gates settled 2026-05-31, clean 2-container topology on every axis:**
- **T086** → HTTP, no TLS, no proxy (Mneme is HTTP; host networking gives both LAN + Tailscale routes free); receiver binds host interfaces, two-origin CORS, API key as sole gate.
- **T087** → `grafana/alloy:v1.5.1` supports native `api_key` + `cors_allowed_origins` → **2 containers, no Caddy**.
- **T088** → pins `grafana/loki:3.3.2` + `grafana/alloy:v1.5.1` (amd64-confirmed).
- **T089** → socket `root:root 660` → `group_add: ["0"]`, uid stays 1026.

Config (Phases 2–5) is authored against this settled shape. One new detail surfaced: Alloy's default UI port 12345 is remapped to 3110 via the `--server.http.listen-addr` flag in compose (the Faro receiver takes 3111).

**Phase 7 (retention-deletion) is deliberately separate from Phase 10 (24h observation).** A 24h window cannot fire a 7-day compactor; Phase 7 proves time-retention deletion via a short-retention test, and installs the operator disk-watch (Loki has no automatic byte-cap — size protection is time-retention + vigilance, stated plainly).

**F004 does NOT block on Mneme F012** (producer ships first, Spec D7). F004 closes on its own synthetic beacon (Phase 6); publishing the contract (Phase 8) is the F012-unparking artifact.

**Total:** 22 tasks (T086–T107).
**Parallelizable:** Phase 0's four checks (T086–T089); the two doc tasks T090/T091.
**Phase 10 (T106) is observation-only:** anomalies generate follow-up issues, do not block F004 close — mirrors F001 T028 / F002 T056 / F003 T083 pattern.
**Note on T107 numbering:** T107 (retrospective stub) is numerically last but executes between T105 (Phase 9 close) and T106 (Phase 10 start). File order reflects execution order.

---

## Phase 0: Pre-flight Gates (F004-unique — topology-branching)

All four are verification-only and can run in parallel `[P]`, but their *outcomes* gate later phases. Capture every result in the PR description.

### T086 — Browser→receiver reachability + TLS edge `[RESOLVED 2026-05-31]`

**Files:** (none; resolution recorded in PR + `docs/logs-setup.md`)

**Resolution (operator network audit):** **HTTP, no TLS, no proxy.** Mneme is served over HTTP on both paths — `http://192.168.0.8:8080` (LAN) and `http://ds224plus.tailda1ab8.ts.net:8080` (Tailscale). No public domain / cert / Let's Encrypt; free-tier Tailscale. Because the Mneme page is HTTP, beacons to an HTTP receiver have no mixed-content constraint and need no TLS; host networking makes the receiver's host port answer on both routes automatically. The DSM-Application-Portal / TLS-edge / Caddy-for-TLS paths are all eliminated.

**Settled consequences (feed T099/T100/T103):**
- Receiver binds **host interfaces** (`0.0.0.0:3111`), NOT localhost — directly reachable on LAN + tailnet, **API key is the sole gate** (documented posture, acceptable single-user).
- CORS allow-list = **two origins**: `http://192.168.0.8:8080` + `http://ds224plus.tailda1ab8.ts.net:8080`, explicit, never `*`.
- Endpoint URLs are **known now** — `http://192.168.0.8:3111` (LAN) and `http://ds224plus.tailda1ab8.ts.net:3111` (Tailscale); no placeholder, no timing gate on the contract (T103).
- Encryption posture: HTTP plaintext on LAN; WireGuard-encrypted on the Tailscale path. No end-to-end TLS, accepted.
- Only residual branch is **T087** (native Alloy key/CORS vs. a tiny **HTTP** Caddy — no TLS either way).

### T087 — Alloy `faro.receiver` capability (api_key + CORS) `[RESOLVED 2026-05-31]`

**Files:** (none; resolution recorded in PR)

**Resolution:** **NATIVE key + CORS confirmed.** `grafana/alloy:v1.5.1` run-validated cleanly with `api_key` and `cors_allowed_origins` in the `faro.receiver` `server` block — the receiver started and bound with no unknown-attribute error. → **2-container topology** (Loki + Alloy), no Caddy. Budget Loki 200M + Alloy 250M = 450M ≤ 500M. Alloy enforces key + two-origin CORS on host interfaces; `config.alloy` (T094/T099) authored against this.

### T088 — Pin Loki + Alloy image versions `[RESOLVED 2026-05-31]`

**Files:** (none; pins feed T093/T095 compose)

**Resolution:** **`grafana/loki:3.3.2` + `grafana/alloy:v1.5.1`** — both have linux/amd64 manifests and both pulled successfully on the NAS. Pinned verbatim in `docker-compose.logs.yml` (no `:latest` — Principle I).

### T089 — Docker socket / D8 mechanism `[RESOLVED 2026-05-31]`

**Files:** (none; feeds T095 compose)

**Resolution:** socket is **`root:root 660`** → **`group_add: ["0"]`** on the Alloy service, `user: "1026:100"` unchanged (the DSM `/volume1` write restriction keys on uid, not supplementary groups, so writes still succeed). Docker data-root confirmed `/volume1/@docker`. D8 **primary** mechanism; no socket-proxy fallback needed. Collection is API-based (socket only — no container-log-path mount).

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
**Then** it covers: (1) bind-mount path pre-creation + `chown 1026:100`; (2) **DSM ACL restart-loop recovery** (`synoacltool -del` + `chown`, memory `project_dsm_acl_recovery`); (3) the **receiver posture** (D5/T086 — HTTP, no TLS, host-interface binding, API-key-as-sole-gate, two-origin CORS, LAN-plaintext / Tailscale-WireGuard encryption note); (4) API-key generation (`openssl rand -base64 32`) + setting `FARO_API_KEY` / `FARO_ALLOWED_ORIGINS` (two origins) in Portainer stack env; (5) the operator disk-watch for Loki (disk-usage check — NOT an automatic size cap; lever is shortening retention); (6) pointer to the published contract block
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
**And** `docs/ports.md` moves Alloy 3110 (UI) + 3111 (faro.receiver, **host interfaces** — D5/T086) into Current assignments (and Caddy 3112 if T087 forced the proxy)

### T096 — Verify container logs in Grafana Explore

**Files:** (none; verification-only)

**Acceptance:**

**Given** Loki + Alloy are running with the Loki datasource not yet added (use Loki's API directly or add the datasource first — see Phase 4 ordering note)
**When** logs are queried in Grafana → Explore → Loki (after T097/T098) or via `logcli`/curl
**Then** Mneme's pino JSON log lines are returned for the Mneme API container, queryable by `{container="<mneme-api-container>"}` (label key `container` per T094; query string illustrative — acceptance is "queryable by container," not a literal label match — Spec Scenario 2)
**And** **the `container` label is actually PRESENT on streams** — verified explicitly by querying `{container="loki"}` and `{container="alloy"}` (the two new containers, whose names are known) and confirming each returns log lines. This is the relabel-wiring check: if these return nothing while logs clearly exist, the `discovery.relabel` → `loki.source.docker` `relabel_rules` wiring failed to apply the label, and the fix is to switch `loki.source.docker` to `targets = discovery.relabel.containers.output` + drop `relabel_rules`. Catch it here at deploy, not later.
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

## Phase 5: Faro Receiver Exposure + Secrets (no TLS edge — D5/T086)

### T099 — Add the `faro.receiver` pipeline to `config.alloy`

**Files:** `config/alloy/config.alloy`

**Acceptance:**

**Given** T087 confirmed (or denied) native Alloy key+CORS, and T086 fixed the HTTP/host-interface posture
**When** the `faro.receiver` pipeline 3 is added
**Then** it binds **`0.0.0.0:3111`** (host interfaces, NOT localhost — D5/T086, so LAN + Tailscale browsers reach it), sets `cors_allowed_origins = split(sys.env("FARO_ALLOWED_ORIGINS"), ",")` (the **two** origins, explicit, never `*`) and `api_key = sys.env("FARO_API_KEY")` (if T087 confirmed native support; else this enforcement lives in the HTTP Caddy per T100)
**And** `output { logs = [loki.write...]; traces = [] }` — **traces output UNWIRED** so trace signals are dropped (FR-49, Scenario 6; the literal in-code APM-deferral seam)
**And** secrets/origins come via `sys.env` (no envsubst/sed templating — sidesteps memory `project_dsm_no_envsubst`)
**And** a config comment documents the host-interface + API-key-as-sole-gate posture (D5/T086)

### T100 — Receiver exposure + secrets (no TLS edge — D5/T086)

**Files:** `.env.example`, `docs/logs-setup.md` (+ `docker-compose.logs.yml` & `docs/ports.md` if Caddy), Portainer stack env (operational)

**Acceptance:**

**Given** T086 resolved the edge to HTTP / host interfaces / no proxy, and T087 chose the enforcement point — **there is no TLS edge to stand up**
**When** receiver exposure is finalized
**Then** the receiver answers over HTTP on `http://192.168.0.8:3111` (LAN) and `http://ds224plus.tailda1ab8.ts.net:3111` (Tailscale) via host networking — verified with a `curl` from both a LAN host and a Tailscale-connected client
**And** `FARO_API_KEY` and `FARO_ALLOWED_ORIGINS` (the two origins, comma-joined) are set in Portainer stack env; `.env.example` documents both variable names (values not committed — v1.3 Secrets)
**And** `docs/logs-setup.md` documents the chosen posture: HTTP (no TLS), host-interface binding, API-key-as-sole-gate, two-origin CORS, and the LAN-plaintext / Tailscale-WireGuard encryption note
**And** if T087 forced the Caddy path: a minimal **HTTP** Caddy container (key + two-origin CORS, no TLS) is added to `docker-compose.logs.yml` on host interfaces, rebalanced ≤ 500M, with its port in `docs/ports.md`
**And** the endpoint URLs are confirmed (feed T103's contract block — already known from T086, this just verifies reachability)

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

**Given** the endpoint URLs are known (T086 — no TLS edge gate) and verified reachable (T100)
**When** the Faro contract block (Plan §Faro contract block) is published into Mneme's `docs/observability.md`
**Then** it states the authoritative producer-owned interface: **both endpoint URLs** (`http://192.168.0.8:3111` LAN + `http://ds224plus.tailda1ab8.ts.net:3111` Tailscale, with the Tailscale one as recommended remote default), **`x-api-key` header name**, the **two CORS allowed-origins**, **accepted signals** (logs/exceptions/events/measurements) and **dropped signals** (traces)
**And** it notes F012 selects the endpoint matching how the browser loaded Mneme, and the HTTP/no-TLS + LAN-plaintext / Tailscale-WireGuard transport posture
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
