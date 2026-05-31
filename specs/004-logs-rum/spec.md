# Feature Specification: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Status:** Draft (2026-05-31) — pending `/plan`
**Created:** 2026-05-31
**Depends on:** Feature 003 complete (2026-04-26); **Constitution v1.3.0** (amended 2026-05-31 — broadened to metrics + logs + RUM, two-subsystem budgets, `3100–3199` port range, APM/Tempo deferred with trace-dropping enforced in code). Mneme's F012 (frontend Faro Web SDK adoption) is the **consumer** of this feature's Faro receiver — but F004 does **not** depend on F012 and does **not** block on it (see D7: producer ships first).

---

## Overview

Feature 004 expands the platform from a metrics-only stack into the **unified observability platform** that Constitution v1.3 describes: metrics (F001–F003, unchanged) plus **logs** and **real-user monitoring (RUM)**, all visualized through the one existing Grafana. It is the first feature implemented under v1.3.

Two upstream services join the stack, in a **new compose file** (`docker-compose.logs.yml`, separate from the metrics `docker-compose.yml` per D2):

- **Grafana Loki** — log aggregation. Single-binary mode, filesystem object store + TSDB shipper, schema v13, 7-day compactor retention with a size guard. The logs counterpart to Prometheus.
- **Grafana Alloy** — the collector. It does two jobs at once: (a) it ships **backend logs** to Loki — container stdout (Mneme's pino JSON and every other container, discovered via the Docker socket) plus host system logs; and (b) it runs the **Faro receiver**, the HTTP endpoint that ingests **frontend telemetry** (errors, web-vitals, sessions) from browsers running the Faro Web SDK, and forwards it to Loki.

The data flows v1.3 codified:

- **Backend logs:** containers (incl. Mneme) → Docker stdout → Alloy (`loki.source.docker`) → Loki → Grafana.
- **Frontend RUM:** browser (Faro Web SDK) → nas-observability-owned reverse proxy (TLS + API key + CORS) → Alloy `faro.receiver` (localhost) → Loki → Grafana.

F004 also touches the **metrics-side Grafana image**: it bakes a Loki datasource (`uid: loki`) into the custom image so logs and RUM are explorable alongside metrics. That is the only change to the metrics subsystem; Prometheus, the exporters, and their 600 MB budget are untouched.

F004 establishes the logs/RUM pattern future apps will reuse, exactly as F003 established the per-application metrics pattern. Its first concrete consumer is Mneme F012, which is parked at its own verification gate waiting for this receiver to exist — **publishing the Faro contract is therefore part of F004's definition of done** (D7), because it is the artifact that unparks F012.

**This feature is APM-bounded by design.** The Faro Web SDK can emit distributed-tracing spans; v1.3 defers APM/Tempo. F004 enforces that deferral *in code*: the receiver accepts logs, exceptions, events, and measurements, and **drops trace signals**. A future tracing feature flips that one output — a clean seam, not a rewrite.

---

## User Scenarios & Testing

### Primary User Story

As Stellar, I want Mneme's backend logs (and every container's logs) and its frontend errors/web-vitals/sessions to land in the same Grafana I already use for metrics, so that when something breaks I can pivot from "the API latency spiked at 14:03" (metric) to "here are the error logs at 14:03" (log) to "and here's the browser exception the user saw" (RUM) without leaving the pane of glass or SSHing into the NAS to `docker logs`.

### Acceptance Scenarios

**Scenario 1: Logs/RUM subsystem deploys without disturbing the metrics subsystem**

**Given** the F001–F003 metrics stack is running (6 containers, 600 MB cap held)
**When** the operator deploys `docker-compose.logs.yml` as a separate Portainer stack
**Then** two new containers (`loki`, `alloy`) enter the `running` state
**And** all six metrics-subsystem containers remain `Up` with no restarts
**And** the logs/RUM declared `mem_limit` sum is ≤ 500 MB (Loki 200M + Alloy 250M = 450M), independent of the metrics 600 MB
**And** observed memory across both subsystems stays well below their respective caps

**Scenario 2: Container logs flow to Loki via Docker discovery**

**Given** Loki and Alloy are running, and Alloy's `loki.source.docker` is reading the Docker socket
**When** the operator opens Grafana → Explore → Loki datasource and queries for the Mneme API container's logs (e.g. `{container="mneme-api-1"}`)
**Then** Mneme's pino JSON log lines appear, parsed, with recent timestamps
**And** an all-streams query returns log streams for every running container including the observability stack's own services
**And** the JSON fields (level, msg, etc.) are queryable as Loki labels or via `| json` parsing

> **Label schema is `/plan`-resolved; query strings here are illustrative.** The label *key* (`container` vs `container_name` vs `instance` vs a custom relabel) is an Alloy `loki.source.docker` discovery/relabeling config detail decided in `/plan`, not a given. The *value* (`mneme-api-1`) tracks Docker's container name. Acceptance is "Mneme's logs are queryable by container in Grafana," NOT a literal match on the label key — the scenario must not fail on a cosmetic label-name difference. `/plan` fixes the canonical label schema and the docs reflect it.

**Scenario 3: Alloy retries gracefully when Loki is unavailable**

**Given** Alloy is configured to push to Loki at `localhost:3100`
**When** Loki is not yet up (or is restarting) at Alloy start time
**Then** Alloy does NOT crash-loop — it logs connection errors and retries with backoff
**And** once Loki becomes available, buffered/subsequent logs flow through with no manual intervention
**And** neither service's restart count climbs over a 10-minute window with Loki cycling

**Scenario 4: Faro receiver accepts a valid beacon and rejects an unauthenticated one**

**Given** the Faro receiver is live behind the reverse proxy with an API key configured and Mneme's frontend origin allow-listed
**When** the operator POSTs a Faro-format payload (a synthetic beacon containing a log + an exception + a measurement) to the receiver's public URL **with** the correct API key and `Origin: <mneme-frontend-origin>`
**Then** the request succeeds (2xx)
**And** the accepted signals appear in Loki, queryable in Grafana (e.g. `{app="mneme-frontend"}` or the agreed RUM label set)
**When** the same payload is POSTed **without** the API key (or with a wrong key)
**Then** the reverse proxy rejects it (401/403) before it reaches Alloy

**Scenario 5: CORS is enforced — Mneme's origin allowed, others refused**

**Given** the receiver's CORS allow-list contains exactly Mneme's frontend origin (never `*`)
**When** a browser preflight (`OPTIONS`) arrives with `Origin: <mneme-frontend-origin>`
**Then** the response carries `Access-Control-Allow-Origin: <mneme-frontend-origin>` and the beacon POST is permitted
**When** a preflight arrives with any other `Origin`
**Then** the allow-origin header is absent and the browser blocks the cross-origin POST

**Scenario 6: Trace signals are dropped (APM deferral enforced in code)**

**Given** the receiver is configured to forward only logs/exceptions/events/measurements
**When** a Faro payload that *includes* trace/span data is POSTed (synthetic, with the valid key + origin)
**Then** the log/exception/measurement portions land in Loki
**And** the trace/span portion is dropped — no trace backend receives it, nothing errors, no Tempo is contacted (there is none)
**And** the receiver's `output` wiring shows the traces output unwired (the documented clean seam for a future tracing feature)

**Scenario 7: Logs visualized alongside metrics in the existing Grafana**

**Given** F004 has baked a Loki datasource (`uid: loki`) into the custom Grafana image and redeployed it
**When** the operator opens Grafana
**Then** both Prometheus (`uid: prometheus`) and Loki (`uid: loki`) datasources are present and healthy (datasource health check passes)
**And** Explore can switch between them
**And** existing F001–F003 metrics dashboards render unchanged (the Grafana image rebuild did not regress them)

**Scenario 8: Retention caps log disk growth at 7 days**

**Given** Loki's compactor is configured with a 7-day retention and a filesystem size guard (whichever binds first)
**When** logs older than 7 days exist (or the size guard is approached)
**Then** the compactor deletes expired chunks/index on its schedule
**And** Loki's on-disk footprint under `/volume1` stays bounded — it does not grow unbounded the way an un-retained log store would
**And** this is verified by a **short-retention test** (temporarily set retention to ~1h, confirm deletion fires, restore 7d) — NOT by the 24h observation, in which a 7-day compactor structurally cannot fire (see *Notes for `/plan`* §phase-8)

**Scenario 9: Bind-mount permissions survive a redeploy (DSM constraints)**

**Given** Loki and Alloy write state to `/volume1` bind mounts and run as the DSM admin UID `1026:100` (per Constitution v1.1)
**When** the stack is brought down and back up (or DSM applies an ACL on the bind-mount path)
**Then** neither service enters the DSM ACL restart-loop failure mode
**And** if it does, the documented recovery (`synoacltool -del` + `chown 1026:100`, per `docs/setup.md`) restores it
**And** the init/setup runbook pre-creates and `chown`s the bind-mount paths so first deploy is clean

**Scenario 10: F004 closes on its own synthetic verification — no dependency on Mneme F012**

**Given** F004's receiver, Loki, Alloy, and Grafana datasource are all deployed and healthy
**When** the operator runs F004's synthetic-beacon verification (Scenario 4 + 5 + 6 combined: keyed POST from the allowed origin, with logs + exception + measurement + trace)
**Then** all of F004's acceptance criteria pass using only signals F004 generates itself
**And** F004 is complete without Mneme having sent any real telemetry
**And** the Faro contract block (endpoint, CORS origins, API-key handling, accepted-vs-dropped signals) has been published in a form that drops into Mneme's `docs/observability.md` — the artifact that unparks F012

### Edge Cases

- **Loki down at Alloy start.** Covered by Scenario 3 — Alloy retries with backoff, no crash-loop. This is a ruled requirement (FR), not best-effort.
- **DSM ACL restart-loop on the new bind mounts.** The primary recurring Docker failure mode on this DS224+ (see memory `project_dsm_acl_recovery`). Both new bind-mount paths (Loki chunks/index, Alloy WAL/positions) MUST document the `synoacltool -del` + `chown` recovery, same discipline as Prometheus/Grafana.
- **DSM UID restriction vs. Docker-socket access (real tension — flagged for `/plan`).** Alloy must both *write* its WAL/positions to a `/volume1` bind mount (→ run as `1026:100` per v1.1) **and** *read* the root-owned Docker socket for `loki.source.docker`. These can conflict on DSM. `/plan` resolves the mechanism (e.g. `group_add` the docker GID, a socket-proxy sidecar, or reading container log files directly from the Docker data path). Surfaced here because it's a known DSM friction, not discovered late.
- **Log volume spikes (e.g. Mneme error storm or a chatty container).** Retention + size guard (Scenario 8) bound disk; if the size guard binds before 7 days, older logs are dropped first. Documented as expected behavior, not a failure. If a single container floods, `/plan` may add per-stream rate limits in Loki — noted, not pre-committed.
- **Faro receiver reachable but Mneme not yet sending.** The receiver sits idle; no error. RUM queries return "no data" cleanly. F012 begins sending when its migration lands — F004 is robust to the consumer not existing yet.
- **Reverse proxy misconfiguration (key or CORS wrong).** Browser beacons fail CORS or get 401. The contract block (D6) documents the exact origin, key header, and endpoint so Mneme's F012 configures the SDK correctly; a mismatch surfaces as a browser console CORS error, diagnosable from the contract.
- **Host networking port collision in the 3100–3199 band.** Loki (HTTP 3100, gRPC 3101), Alloy (UI 3110, Faro receiver 3111) all bind host ports. If DSM or another service holds one, deploy fails loudly (Principle III). `ss -tlnp | grep <port>` diagnoses, per `docs/setup.md`.
- **Grafana image rebuild regresses an existing dashboard.** F004 rebuilds the custom Grafana image to add the Loki datasource. The build's existing verification (dashboard provisioning, datasource UIDs) must still pass; Scenario 7 confirms F001–F003 dashboards render unchanged post-rebuild.
- **Alloy reads its own logs / feedback loop.** `loki.source.docker` discovers *all* containers, including Alloy and Loki themselves. Benign (their logs are useful) but worth noting; no special handling unless volume warrants it.

---

## Requirements

### Functional Requirements

- **FR-45:** The system MUST add a **new compose file** `docker-compose.logs.yml` (separate from `docker-compose.yml`) defining two services — `loki` and `alloy` — each with `network_mode: host`, `restart: unless-stopped`, a pinned upstream image (verified at plan time), and an explicit `mem_limit`. The metrics `docker-compose.yml` MUST be unchanged except as required to rebuild the Grafana image (FR-52). [Constitution v1.3: Principles I, III, IV; D2]
- **FR-46:** `loki` MUST run Grafana Loki in **single-binary mode** with **filesystem** object storage + **TSDB shipper**, **schema v13**. It MUST NOT depend on any external object store. [Constitution v1.3: Principle I; D3]
- **FR-47:** Loki retention MUST be enforced by the **compactor** at **7 days**, with a **filesystem size guard** — whichever binds first. Retention MUST be finite from first deploy; it MUST NOT be left at Loki's unbounded default. [Constitution v1.3: Principle IV §logs/RUM 7-day retention]
- **FR-48:** `alloy` MUST ship **backend logs** to Loki: container stdout via `loki.source.docker` (Docker-socket discovery — covers Mneme's pino JSON and all other containers) plus host system logs. Mneme requires **no application-side change** to be collected — its existing JSON-to-stdout logging is sufficient. [Constitution v1.3: Observability coverage §Logs; Q-answer: Docker stdout discovery]
- **FR-49:** `alloy` MUST run a **Faro receiver** (`faro.receiver`) that accepts frontend telemetry and forwards it to Loki. The receiver's `output` MUST wire **logs only**; the **traces output MUST be left unwired** so trace/span signals are dropped. This enforces v1.3's APM/Tempo deferral in code, not prose. Accepted signal classes: logs, exceptions, events, measurements. [Constitution v1.3: Observability scope boundaries; ruling #6]
- **FR-50:** Alloy MUST **retry gracefully** if Loki is unavailable at start or during operation — connection failures MUST NOT cause a crash-loop; Alloy retries with backoff and resumes when Loki returns. [ruling #2]
- **FR-51:** The Faro receiver MUST bind **localhost** and sit behind a **nas-observability-owned reverse proxy** that enforces **TLS + API key + CORS**. CORS allowed-origins MUST be set to Mneme's frontend origin explicitly and MUST NEVER be `*`. The API key MUST live in the gitignored `.env` (per v1.3 Secrets). The reverse-proxy *placement* (DSM Application Portal vs. an in-repo proxy container) is deferred to `/plan` (D5); the *enforcement contract* (TLS + key + CORS, receiver on localhost) is fixed here. [Constitution v1.3: Principle III, Secrets; ruling #4]
- **FR-52:** The custom Grafana image MUST bake a **Loki datasource** with explicit `uid: loki` (URL `http://localhost:3100`) alongside the existing `uid: prometheus`. This is the only change to the metrics subsystem. The image is rebuilt and redeployed; existing F001–F003 dashboards MUST render unchanged. [Constitution v1.1: datasource UIDs must be explicit; v1.3: one Grafana]
- **FR-53:** `loki` and `alloy` MUST run as the DSM admin UID `1026:100` (via compose `user:`) because both persist state to `/volume1` bind mounts (Loki: chunks + index; Alloy: WAL + positions). The bind-mount host paths MUST be declared in `docker-compose.logs.yml` AND documented in `docs/setup.md` with the UID/GID guidance and the DSM ACL restart-loop recovery. [Constitution v1.1: DSM UID restriction, baked-vs-state; memory `project_dsm_acl_recovery`]
- **FR-54:** The system MUST update `docs/ports.md`, moving the F004 reservations into "Current assignments": **Loki HTTP 3100**, **Loki gRPC 3101**, **Alloy UI 3110**, **Alloy Faro receiver 3111** — all within the `3100–3199` logs/RUM range. Loki's gRPC port MUST be remapped into the band (off its upstream default 9095, which would otherwise sit in the Prometheus-adjacent range). [Constitution v1.3: Principle III, `3100–3199` range]
- **FR-55:** Logs/RUM subsystem `mem_limit` sum MUST stay within the **500 MB** logs/RUM cap (independent of the metrics 600 MB cap): Loki 200M + Alloy 250M = 450M, leaving 50M headroom. [Constitution v1.3: Principle IV §two-subsystem budgets]
- **FR-56:** F004 MUST **publish the Faro receiver contract** in a form that drops into Mneme's `docs/observability.md`: the receiver endpoint (public proxy URL), CORS allowed-origins, API-key handling, and the accepted-vs-dropped signal classes. Publishing this contract is part of F004's definition of done — it is the artifact that unparks Mneme F012. F004 does **not** wait for Mneme to consume it. [D6, D7]
- **FR-57:** F004's completion MUST be verifiable via a **synthetic Faro beacon** that F004 sends itself (keyed POST from the allowed origin, containing logs + exception + measurement + trace): confirming the key is enforced, CORS is applied, traces are dropped, and accepted signals land in Loki. F004 MUST NOT couple its close-out to Mneme F012 actually sending telemetry; real end-to-end integration is F012's own Phase 2 gate. [D7]
- **FR-58:** Every PR in this feature MUST satisfy the constitutional compliance checklist as amended by v1.3: pinned version, explicit `mem_limit`, **total within the relevant subsystem's cap (logs/RUM ≤ 500 MB)**, host ports declared in `docs/ports.md`, bind mounts documented. [Constitution v1.3: Governance §Compliance gates]

### Non-Functional Requirements

- **NFR-18:** Logs/RUM observed memory SHOULD remain below 70% of the 500 MB cap. If observed memory approaches the cap, investigate (Loki cardinality, Alloy buffer sizing) before raising any `mem_limit` — and if a raise is genuinely needed, amend the constitution per Principle IV rather than silently exceeding 500 MB. [Constitution v1.3: Principle IV]
- **NFR-19:** The Faro receiver MUST respond to a valid keyed beacon within a reasonable budget (target < 500 ms server-side) so browser RUM beaconing does not stall the frontend. (Tightened/confirmed at plan time.)
- **NFR-20:** Loki query latency for a typical Explore query (single container, last 1h) SHOULD return within 3 seconds, matching the dashboard-render baseline (F002 NFR-8 / F003 NFR-14).
- **NFR-21:** Loki's on-disk footprint under `/volume1` MUST stay bounded by the 7-day retention + size guard. The size guard value is set at plan time against expected log volume; hitting it is a volume signal to investigate, not a reason to expand retention.
- **NFR-22:** Adding the Loki datasource and rebuilding the Grafana image MUST NOT regress metrics-subsystem startup or dashboard rendering. Verified post-deploy (Scenario 7).

### Key Entities

- **Loki** (`grafana/loki`, pinned): single-binary log-aggregation service. Filesystem store + TSDB shipper, schema v13, compactor retention 7d + size guard. Binds host ports 3100 (HTTP) and 3101 (gRPC, remapped into band). Writes chunks + index to a `/volume1` bind mount; runs as `1026:100`. `mem_limit` 200M. The logs counterpart to Prometheus.
- **Alloy** (`grafana/alloy`, pinned): the collector. Components: `loki.source.docker` (container-log discovery via Docker socket), host-log source, `faro.receiver` (frontend RUM ingest on localhost:3111), and the `loki.write`/output wiring to Loki. UI on 3110. Writes WAL/positions to a `/volume1` bind mount; runs as `1026:100` (Docker-socket access mechanism resolved in `/plan`). `mem_limit` 250M.
- **Faro receiver**: the `faro.receiver` component inside Alloy. Accepts logs/exceptions/events/measurements; traces output unwired (dropped). Bound to localhost; exposed to browsers only through the reverse proxy.
- **Reverse proxy (nas-observability-owned)**: terminates TLS, checks the API key, sets CORS for Mneme's origin, forwards to the localhost Faro receiver. DSM-Application-Portal-vs-container placement resolved in `/plan`.
- **Loki datasource**: provisioned into the custom Grafana image at build time, `uid: loki`, URL `http://localhost:3100`. Sister to the existing `uid: prometheus` datasource.
- **Faro contract block**: the F004 deliverable published into Mneme's `docs/observability.md` — endpoint, CORS origins, API-key handling, accepted-vs-dropped signals. The artifact that unparks F012.
- **`docs/logs-setup.md`** (working name): NAS-side runbook for the logs/RUM subsystem — bind-mount pre-creation + `chown`, reverse-proxy setup, API-key generation, contract publication. Sister doc to `docs/snmp-setup.md` and `docs/mneme-setup.md`.

---

## Specific Decisions (resolved in this spec)

### D1. Subsystem budget — logs/RUM ≤ 500 MB, separate from metrics

Loki 200M + Alloy 250M = 450M, within the v1.3 logs/RUM cap of 500M (50M headroom). Kept legibly separate from the metrics 600M cap, never merged. The cap is a discipline tripwire, amendable upward per Principle IV if a genuine need arises (~3.8 GB free on the NAS). Per-service `mem_limit` discipline continues. [Ruling #1]

### D2. Two compose files — metrics and logs/RUM are operationally independent

F004 ships `docker-compose.logs.yml` (Loki + Alloy) separate from the metrics `docker-compose.yml`. Rationale: the two subsystems restart independently, the split mirrors the two-budget structure, and Portainer deploys them as two stacks. The one coupling is **Grafana**, which lives in the metrics file and visualizes both subsystems via a baked Loki datasource (FR-52) — that coupling is in the baked image, not compose, so the file split stays clean. [Ruling #2]

### D3. Loki — single-binary, filesystem, schema v13

Single-binary mode is the obvious fit for a single-operator homelab (no microservices split, no external object store). Filesystem object store + TSDB shipper, schema v13. Confirmed over any object-store ambition. [Ruling #3]

### D4. Log retention — 7 days

Loki retention is **7 days** (vs. the metrics subsystem's 30-day Prometheus retention), enforced by the compactor with a size guard, whichever binds first. Logs are the stack's largest disk-consumption risk and single-operator debugging rarely looks back two weeks; 7d is the disciplined default, trivially amendable upward via constitution if needed. [Ruling #3]

### D5. Faro receiver auth — reverse proxy enforces, placement deferred to `/plan`

The receiver binds localhost behind a **nas-observability-owned reverse proxy** that enforces **TLS + API key + CORS** (Alloy's native `faro.receiver` auth is limited; the proxy is the right enforcement layer). The contract — receiver-on-localhost, proxy-enforces-key/CORS, origins explicit and never `*` — is fixed in this spec. The **placement** — DSM's built-in Application Portal reverse proxy (no new container, documented runbook step) vs. an in-repo proxy container (fully declarative per Principle II, but costs RAM against the 500M cap and adds a port-table entry) — is deferred to `/plan`, which checks what DSM 7.3's Application Portal can actually enforce (key auth + CORS headers) before choosing. [Ruling #4, Q-answer]

### D6. Faro contract block — an F004 deliverable

F004 produces the contract block that Mneme's F012 consumes, published into Mneme's `docs/observability.md`: endpoint (public proxy URL), CORS allowed-origins (Mneme's frontend origin), API-key handling, accepted-vs-dropped signal classes. This is **part of F004's done** — it is the thing that unparks F012. The exact contents are finalized in `/plan` once the proxy placement (D5) fixes the public URL. [Q-answer]

**Timing dependency — the contract URL is gated on D5.** The single most consequential field, the endpoint URL, cannot be finalized until D5 (reverse-proxy placement) resolves in `/plan`, because placement determines the public URL Mneme posts to. So F012 does **not** fully unpark at F004-*merge*; it unparks at F004's contract-*publication*, which is post-D5-resolution. Until D5 resolves, Mneme F012 can only wire its SDK against a **placeholder** URL (everything else in the contract — key handling, CORS origin, accepted-vs-dropped signals — is fixed by this spec and stable). This keeps the cross-repo timing honest: F004-merge ships the receiver; F004-contract-publication (after D5) is what Mneme can finally point at.

### D7. F012 coupling — producer ships first; F004 verifies itself

Two distinct gates, deliberately separated:

- **Merge gating:** F004 does **NOT** block on Mneme F012. The dependency runs producer→consumer — the mirror of F003 with roles reversed. F003: Mneme produced metrics, this repo consumed, so this repo waited on Mneme's contract doc. F004: this repo produces the Faro receiver, Mneme consumes, so **Mneme (F012) waits on F004**. F012 is explicitly parked waiting for F004's live receiver; if F004 blocked on F012 it would deadlock. So F004 merges independently, ships the receiver, publishes the contract — and *that* unparks F012. Same producer-ships-first rule as F003, repos in opposite roles.
- **Close-out gating:** F004's completion is gated on F004 proving its **own** receiver works — via a **synthetic Faro beacon** F004 sends itself (FR-57): Faro-format POST → API key enforced → CORS applied → traces dropped → accepted signals land in Loki. Fully within F004's control, no F012 dependency. The real end-to-end (actual Mneme frontend telemetry through the live receiver) is owned by **F012's Phase 2 gate** ("verify Mneme's Faro telemetry lands in Loki end-to-end") — that single consumer-side verification confirms both that F012 sends correctly and that F004's receiver serves a real client. It is **not** duplicated as an F004 close-out coupling.

Producer proves the receiver works; consumer proves the integration works. No deadlock, no double-verification, integration still genuinely verified before F012 deletes its old error-tracking path. [Q-answer]

### D8. Alloy Docker-socket access vs. DSM UID restriction — flagged for `/plan`

Alloy must both *write* WAL/positions to `/volume1` (→ run as `1026:100` per v1.1) and *read* the root-owned Docker socket for `loki.source.docker`. These can conflict on DSM 7.3. `/plan` resolves the mechanism: candidate options are `group_add` the docker GID, a read-only socket-proxy sidecar, or pointing `loki.source.docker`/a file source at the Docker container-log path directly. Surfaced now because it's a known DSM friction class (the F001 retro lesson: upstream Docker conventions don't always hold on DSM), not a late surprise. [Constitution v1.1]

### D9. PR shape — single PR by default

F004 ships as a single integrated PR by default: `docker-compose.logs.yml` (Loki + Alloy configs), the Grafana Loki-datasource bake, ports + docs, the reverse-proxy setup, and the synthetic-beacon verification. If the diff grows unwieldy, a natural split is (a) Loki + backend-log pipeline, (b) Faro receiver + reverse proxy + contract — judgment call at implementation time, not a pre-commitment. (Mirrors F003 D6.)

---

## Success Criteria

This feature is complete when:

1. `docker-compose.logs.yml` deploys two containers (`loki`, `alloy`); logs/RUM declared `mem_limit` sums to ≤ 500M; the metrics subsystem's six containers and 600M cap are untouched.
2. Grafana shows both `uid: prometheus` and `uid: loki` datasources healthy; F001–F003 dashboards render unchanged after the image rebuild.
3. Container logs (incl. Mneme's pino JSON) are queryable in Grafana → Explore → Loki, with no Mneme application-side change.
4. Alloy does not crash-loop when Loki is down; it retries and resumes (verified by cycling Loki).
5. The Faro receiver, behind the reverse proxy, accepts a keyed beacon from Mneme's allowed origin and rejects an unkeyed/wrong-origin one; CORS is enforced (never `*`).
6. A synthetic Faro beacon containing a trace confirms traces are **dropped** while logs/exceptions/measurements land in Loki — the APM-deferral seam is verified in code.
7. Loki's on-disk footprint is bounded by 7-day retention + size guard.
8. Loki and Alloy survive a down/up cycle without the DSM ACL restart-loop (or recover via the documented runbook); bind-mount paths are pre-created and `chown`ed.
9. `docs/ports.md` reflects 3100/3101/3110/3111 as current assignments in the `3100–3199` band.
10. The **Faro contract block is published** in a form ready to drop into Mneme's `docs/observability.md` — F012's unparking artifact (FR-56/D6).

Explicitly not required for this feature:

- **Mneme actually sending real frontend telemetry** — that's F012's Phase 2 gate, not F004's (D7).
- **APM / distributed tracing / Tempo** — deferred by v1.3; F004 drops traces and leaves the clean seam.
- **Alerting on logs/RUM** (e.g. Loki ruler, error-rate alerts) — the dedicated alerting feature's scope.
- **Log/RUM dashboards** (curated panels) — F004 ships Explore-based access + the datasource; curated logs/RUM dashboards can follow once query patterns settle. (Decide at plan whether a minimal starter dashboard is in scope.)
- **Other apps' logs/RUM** — F004 establishes the pattern; per-app onboarding is future work.

---

## Out of Scope

- **APM / distributed tracing (Grafana Tempo)** — deferred by Constitution v1.3. The Faro receiver drops trace signals; a future feature wires the traces output to a backend. This is the documented clean seam, not a TODO inside F004.
- **Alerting on logs or RUM** — no Loki ruler, no error-rate alert rules, no Alertmanager wiring. Belongs to the dedicated alerting feature (still unbuilt).
- **Mneme application-side changes** — F004 needs none. Mneme's existing JSON-to-stdout logging is collected as-is; Mneme's F012 (Faro SDK adoption) is the *consumer* of F004's receiver and is owned by the Mneme work stream.
- **Curated logs/RUM Grafana dashboards** — F004 ships the Loki datasource + Explore access; whether a minimal starter dashboard lands is a `/plan` call. Rich curated dashboards are follow-up work.
- **External object storage for Loki** (S3/MinIO) — filesystem store only (D3). Not justified at single-operator scale.
- **Multi-tenancy / auth inside Loki** — single-operator; Loki runs in single-tenant mode behind the host firewall. (The Faro receiver's browser-facing surface is the only externally reachable endpoint, and it's protected by the reverse proxy.)
- **Replacing Promtail** — not applicable; F004 uses Alloy from the start (Promtail is EOL; Alloy provides collector + Faro receiver in one binary). [Ruling #8]
- **Multi-arch Grafana image / Walkgen snmp.yml** — F002/F003 carry-overs, still deferred per their own trigger criteria.

---

## Notes for `/plan` and `/tasks`

When this feature is planned, `plan.md` resolves the following (explicitly deferred from this spec):

- **Image version pins.** Verify `grafana/loki:<tag>` and `grafana/alloy:<tag>` exist via `docker manifest inspect` at plan time (F001's lesson: upstream tag assumptions occasionally lie). Pin both with semver.
- **Reverse-proxy placement (D5).** Check what DSM 7.3's Application Portal reverse proxy can enforce (custom auth header / API key, CORS response headers). If it can, prefer it (no RAM cost, runbook step). If it can't, add a minimal in-repo proxy container (and account for its `mem_limit` against the 500M cap + a port-table entry). Decide and document.
- **Alloy Docker-socket access (D8).** Resolve `group_add` docker GID vs. socket-proxy sidecar vs. direct container-log-path read, on DSM 7.3 specifically. Confirm Alloy can read container logs while running as `1026:100`.
- **Loki config.** Exact `loki-config.yaml`: single-binary, filesystem paths under `/volume1`, TSDB shipper, schema v13 `from:` date, compactor retention 7d + `retention_enabled: true`, size guard value (set against expected volume), gRPC port remapped to 3101.
- **Alloy config.** Exact `config.alloy`: `loki.source.docker` (with the D8 socket mechanism), host-log source, `faro.receiver` on localhost:3111 with logs-only output (traces unwired — FR-49/Scenario 6), `loki.write` to localhost:3100, UI on 3110.
- **Bind-mount paths + init runbook.** Decide `/volume1/...` paths for Loki (chunks/index) and Alloy (WAL/positions); pre-create + `chown 1026:100`; document the DSM ACL restart-loop recovery (memory `project_dsm_acl_recovery`).
- **Synthetic beacon (FR-57).** How F004 generates it — a `curl` with a hand-built Faro-format JSON payload, or Faro's own test tooling. Define the payload (a log + exception + measurement + a trace, to prove the drop) and the Loki queries that confirm landing.
- **Contract block contents (FR-56/D6).** Finalize once D5 fixes the public URL: endpoint, CORS origin(s), API-key header name + handling, accepted-vs-dropped signal classes. Coordinate the drop into Mneme's `docs/observability.md`.
- **Grafana Loki-datasource bake (FR-52).** Exact `docker/grafana/provisioning/datasources/` diff (`uid: loki`, URL, jsonData). Confirm the image-build verification still passes and dashboards don't regress.
- **Starter dashboard?** Decide whether a minimal logs/RUM Explore-saved or starter dashboard ships in F004 or defers.
- **`.env.example` + Secrets.** Add the Faro API key (and any reverse-proxy secret) to `.env.example`.

`tasks.md` will decompose into phases mirroring F002/F003 but for F004's scope: (1) Loki config + deploy; (2) Alloy backend-log pipeline (Docker-socket mechanism per D8) + verify container logs in Loki; (3) Grafana Loki-datasource bake + rebuild + no-regression check; (4) Faro receiver config (logs-only, traces dropped) + reverse-proxy setup (per D5) + API key/CORS; (5) synthetic-beacon verification (FR-57 — key/CORS/trace-drop/landing); (6) publish the Faro contract block into Mneme's `docs/observability.md` (FR-56 — the F012-unparking artifact); (7) DS224+ deploy + acceptance walk-through; (8) stability observation over **24 hours** matching F002/F003 discipline.

**The phase-8 observation characterizes two things, and explicitly NOT a third:**
- ✅ **Ingestion stability** — Alloy keeps up with real container-log load, the Faro receiver stays responsive, no crash-loop, no memory creep against the 500M cap. The diurnal argument (Mneme day/night usage, Hyper Backup, scheduled jobs) holds, same as F003.
- ✅ **Disk growth *rate*** — measure the rate over 24h and extrapolate ("will 7 days of logs fit under the size guard?"). Extrapolation, not observation of the steady state.
- ❌ **NOT retention-deletion.** The compactor's 7-day deletion CANNOT fire in a 24h window — nothing is 7 days old yet, so 24h shows monotonic growth with zero deletion. The 24h observation says nothing about whether deletion works.

**Retention-deletion (Scenario 8 / FR-47) is verified SEPARATELY**, not by the 24h window:
- **Short-retention test:** temporarily set Loki retention to ~1h, ingest, confirm the compactor deletes expired chunks/index on schedule, then restore 7d. This proves the deletion mechanism is wired and fires.
- **OR a size-guard trip:** if log volume is high enough to bind the size guard within the window, that confirms the size-guard path. (Less reliable — volume-dependent; the short-retention test is the deterministic check.)
- `/plan` picks the mechanism and adds it as its own task, distinct from the 24h observation.
