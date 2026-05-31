# Implementation Plan: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-05-31

---

## Technical Context

F004 is the first feature implemented under Constitution v1.3.0, which broadened the platform from metrics-only to metrics + logs + RUM and split Principle IV into two subsystem budgets. It adds a **logs/RUM subsystem** — Grafana Loki + Grafana Alloy — in a separate `docker-compose.logs.yml`, leaving the F001–F003 metrics subsystem untouched except for one additive change to the baked Grafana image (a Loki datasource).

The component count is small (two services), but the substantive work is in three contract surfaces, the same way F003's weight was in *its* contract surfaces:
1. **The Faro receiver's browser-facing edge** — TLS + API-key + CORS enforcement, and the cross-repo contract block that unparks Mneme F012.
2. **DSM platform frictions** — the Docker-socket-read vs. `/volume1`-write UID tension (Spec D8), the Portainer relative-bind-mount trap (configs must live at absolute host paths), and the recurring ACL restart-loop.
3. **The APM-deferral seam** — wiring the receiver's output to logs only, with traces structurally dropped, so a future tracing feature flips one output.

This plan **resolves Spec D5 (proxy placement) and D8 (socket access)** to concrete topologies, names the image targets, drafts the Loki and Alloy configs, and defines the synthetic-beacon verification and the contract block — leaving only impl-time verifications (exact tag pins, DSM socket ownership, Alloy `faro.receiver` capability) as gated pre-flight tasks, in the same spirit as F003's T075 metric-name verification.

**Runtime & images:**
- `grafana/loki` — target latest-stable **3.x**; exact patch pinned and `docker manifest inspect`-verified at impl (Pre-flight, Phase 0). Upstream, unmodified, config bind-mounted at runtime (Principle I).
- `grafana/alloy` — target latest-stable **v1.x**; same manifest-verification at impl. Upstream, unmodified, config bind-mounted.
- Custom Grafana image rebuilds with a Loki datasource added; no other metrics-side change.
- All F001–F003 images/versions unchanged.

**Cross-repo relationship (producer→consumer, F004 ships first — Spec D7):**
- F004 **produces** the Faro receiver; Mneme **F012 consumes** it. F012 is parked waiting for this receiver. F004 does **not** block on F012 — blocking would deadlock. F004 merges independently, then publishes the contract block, which is what unparks F012.
- The contract's **endpoint URL** can't finalize until D5's reverse-proxy edge is stood up (it fixes the public URL); until then F012 wires against a placeholder. Everything else in the contract (key handling, CORS origin, accepted/dropped signals) is fixed by the spec.

**Networking:** `network_mode: host` throughout (Principle III). Ports in the v1.3 `3100–3199` logs/RUM band: Loki HTTP **3100**, Loki gRPC **3101** (remapped off upstream 9095 to keep the subsystem contiguous and avoid the Prometheus-adjacent 9090–9099 band), Alloy UI **3110**, Alloy `faro.receiver` **3111** (localhost-bound).

**User:** Loki and Alloy both run as `user: "1026:100"` (DSM admin UID) because both persist state to `/volume1` bind mounts (v1.1 DSM UID restriction). Alloy additionally needs Docker-socket read access — resolved in §D8 below without giving up the `1026:100` identity.

**Bind mounts (new):** Loki state (chunks + index + compactor working dir), Alloy state (WAL + positions), and read-only config mounts for both. Per the Portainer constraint (memory `project_portainer_bind_mounts`), config files live at **absolute host paths** under `/volume1`, populated by the init script via `curl` — relative mounts from the repo fail because Portainer's workspace is inside its own container.

---

## Constitution Check

Measured against [`constitution.md`](../../.specify/memory/constitution.md) **v1.3.0**.

| Constraint | Status | Notes |
|---|---|---|
| I. Upstream-First, Thin Customization | ✅ Pass | `grafana/loki` + `grafana/alloy` unmodified at pinned versions; config via runtime bind mounts, not baked. Custom image stays Grafana-only. No fork. |
| II. Declarative Configuration | ✅ Pass | `docker-compose.logs.yml`, `loki-config.yaml`, `config.alloy`, and the Loki datasource provisioning all committed. The DSM Application Portal TLS edge (§D5) is a documented one-time runbook step — the carved-out manual-step exception, mirroring SNMP enablement. Key + CORS enforcement is declarative in Alloy config (`sys.env`), not clicked in a UI. |
| III. Host Networking by Default | ✅ Pass | `network_mode: host`. Ports 3100/3101/3110/3111 in the `3100–3199` band; `docs/ports.md` moves them to Current assignments (FR-54). |
| IV. Resource Discipline | ✅ Pass | Logs/RUM `mem_limit` sum = **450M ≤ 500M** (Loki 200 + Alloy 250), independent of the metrics 600M (untouched). Loki retention **7d** + size guard; Prometheus 30d unchanged. |
| V. Silent-by-Default Alerting | N/A | No alerts shipped in F004 (logs/RUM alerting is the dedicated alerting feature's scope). |
| v1.1 §DSM UID restriction | ✅ Pass | Loki + Alloy run `user: "1026:100"` for `/volume1` writes. Alloy's socket access solved without dropping that UID (§D8). |
| v1.1 §Separate baked config from persisted state | ✅ Pass | Upstream images (no baking). Config mounted read-only at `/etc/<svc>/`; state at distinct `/volume1` paths → container `/loki`, `/var/lib/alloy`. No state mount masks a config path. |
| v1.1 §Grafana datasource UIDs must be explicit | ✅ Pass | Loki datasource declares `uid: loki` (FR-52), alongside existing `uid: prometheus`. |
| v1.3 §Observability scope boundaries (no APM/Tempo) | ✅ Pass — enforced in code | `faro.receiver` `output` wires `logs` only; `traces` output left unwired → trace signals dropped (FR-49, Scenario 6). Clean seam for a future tracing feature. |
| v1.3 §Two-subsystem budgets | ✅ Pass | Logs/RUM cap (500M) tracked separately from metrics cap (600M); never merged. |

**Violations:** none.

---

## Project Structure

### Files introduced / modified by this feature

```
nas-observability/
├── docker-compose.logs.yml            # NEW — Loki + Alloy (separate stack, Spec D2)
│
├── config/
│   ├── loki/
│   │   └── loki-config.yaml            # NEW — single-binary, filesystem, schema v13, 7d retention
│   └── alloy/
│       └── config.alloy                # NEW — loki.source.docker + host logs + faro.receiver + loki.write
│
├── docker/
│   └── grafana/
│       └── provisioning/
│           └── datasources/
│               └── datasources.yaml    # MODIFIED — add Loki datasource (uid: loki)
│
├── scripts/
│   └── init-nas-paths.sh               # MODIFIED — create+chown Loki/Alloy /volume1 dirs; curl their configs
│
├── docs/
│   └── logs-setup.md                   # NEW — bind-mount runbook, DSM reverse-proxy TLS edge, API-key gen, contract publication
│
└── (also modified: docs/ports.md, docs/setup.md, docs/deploy.md, .env.example, README.md)
```

### Cross-repo artifact (not in this repo)

```
mneme/
└── docs/observability.md               # MODIFIED in Mneme — F004 publishes the Faro contract block here (FR-56)
```

### What this feature does NOT introduce

- No APM / Tempo / trace backend (v1.3 deferral; traces dropped at the receiver).
- No log/RUM alert rules, no Loki ruler, no Alertmanager wiring.
- No curated logs/RUM Grafana dashboards (§Starter dashboard decision below — deferred; Explore covers F004).
- No custom Loki or Alloy image (Principle I — upstream + bind-mounted config is sufficient).
- No change to `prometheus.yml` → the `honor_labels` count-gate (`expected=2`) is unaffected.
- No external object store for Loki (filesystem only, Spec D3).
- No Promtail (Alloy from the start — Promtail EOL, Spec ruling #8).

---

## D5 (resolved): Faro receiver edge — DSM does TLS, Alloy enforces key + CORS

**The enforcement contract (fixed by spec):** TLS + API key + CORS; receiver bound to localhost; CORS origins explicit, never `*`.

**Resolved topology:**

```
Browser (Faro Web SDK)
   │  HTTPS, x-api-key header, Origin: <mneme-frontend-origin>
   ▼
DSM Application Portal reverse proxy  ── owns :443, DSM-managed cert, TLS termination
   │  HTTP → localhost
   ▼
Alloy  faro.receiver  (localhost:3111)  ── enforces api_key + cors_allowed_origins natively
   │
   ▼
Loki (localhost:3100)   [logs/exceptions/events/measurements only; traces dropped]
```

**Why this split:**
- **DSM owns :443** — it's in the forbidden-ports table; external HTTPS on this DS224+ goes through DSM's Application Portal regardless. Using it for TLS termination is the path of least resistance and needs no cert management from us (DSM handles Let's Encrypt). This is the one manual runbook step (Principle II carved exception), documented in `docs/logs-setup.md`.
- **Alloy enforces key + CORS** — Alloy's `faro.receiver` `server` block exposes `api_key` and `cors_allowed_origins`. Putting enforcement here keeps it **declarative** (Principle II) in `config.alloy` via `sys.env("FARO_API_KEY")`, rather than relying on DSM's reverse proxy (which can add CORS response headers but **cannot** reject on a missing/wrong API key — it does no request authentication). No extra proxy container, so the subsystem stays at two services and the 450M budget holds.

**Impl-time verification (Phase 0 gate):** confirm the pinned Alloy version's `faro.receiver` supports `api_key` **and** `cors_allowed_origins` in its `server` block. **Fallback if it does not:** add a minimal in-repo Caddy container (HTTP, localhost) doing key-check + CORS + proxy to `:3111`; rebalance to Loki 200 / Alloy 210 / Caddy 40 = 450M, and add Caddy on port 3112 + a `docs/ports.md` row. The fallback is fully specified so impl can take it without re-planning.

---

## D8 (resolved): Alloy Docker-socket access without dropping UID 1026:100

Alloy must simultaneously **write** WAL/positions to `/volume1` (→ run as `1026:100`, per v1.1) and **read** the root-owned Docker socket for `loki.source.docker` (container discovery + log streaming via the Docker API).

**Resolved mechanism — `group_add` the socket's group:** keep `user: "1026:100"` (uid unchanged → `/volume1` writes succeed, files owned `1026:100`), and add the GID that owns `/var/run/docker.sock` to Alloy's supplementary groups via compose `group_add:`. On DSM the socket is typically `root:root` mode `660`, so `group_add: ["0"]` grants the group-read needed to call the Docker API. The uid stays 1026, so this does **not** affect the DSM `/volume1` write restriction (which keys on uid, not supplementary groups).

```yaml
  alloy:
    user: "1026:100"
    group_add:
      - "0"            # GID owning /var/run/docker.sock — VERIFY at impl (Phase 0)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /volume1/@docker/containers:/var/lib/docker/containers:ro   # log-file bodies for loki.source.docker
```

**Impl-time verification (Phase 0 gate):** `stat -c '%U:%G %a' /var/run/docker.sock` on the DS224+ to confirm owner/group/mode and the exact GID to add. Also confirm the container-log path (DSM's Docker data-root is `/volume1/@docker`).

**Security note + fallback:** `group_add: ["0"]` grants Alloy group-root read, which over a mode-660 socket is effectively full Docker-API access (it only *does* GETs, but the capability is broad). Acceptable for a single-operator homelab. **Fallback if a tighter grant is wanted:** a read-only `tecnativa/docker-socket-proxy` sidecar (runs as root, exposes a filtered read-only Docker API on a localhost TCP port; Alloy points `loki.source.docker` at `tcp://localhost:<port>` and stays unprivileged). Costs ~20M (rebalance Alloy 230 / proxy 20) + a port-table row. Documented so impl can escalate to it if the bare `group_add` is judged too broad.

---

## Service Configuration: Loki

**Image:** `grafana/loki:<3.x pinned at impl>` · **Ports:** 3100 (HTTP), 3101 (gRPC) · **mem_limit:** 200M · **user:** `1026:100` · **restart:** `unless-stopped`

**`config/loki/loki-config.yaml` (skeleton — exact values finalized at impl):**

```yaml
auth_enabled: false                      # single-tenant homelab behind host firewall

server:
  http_listen_port: 3100
  grpc_listen_port: 3101                 # remapped off upstream 9095 into the 3100–3199 band

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki                     # → /volume1 bind mount
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2026-05-31                   # schema v13 / TSDB from first deploy
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache

limits_config:
  retention_period: 168h                 # 7 days (Spec D4)
  # ingestion/stream limits + per-stream rate caps tuned at impl against observed volume

compactor:
  working_directory: /loki/compactor
  retention_enabled: true                # enables deletion (default is OFF)
  delete_request_store: filesystem

# Size guard (whichever binds first with 7d): enforced via a periodic disk check
# documented in docs/logs-setup.md; exact mechanism + threshold set at impl vs. observed volume.
```

**Notes:**
- `retention_enabled: true` is the line that makes the 7d cap actually delete — Loki's default leaves it OFF (unbounded). FR-47.
- The **size guard** is the "whichever binds first" companion to 7d. Loki's filesystem store has no native total-size eviction the way Prometheus' `--storage.tsdb.retention.size` does; impl picks the mechanism (a documented disk-usage check + alert-to-operator, or a shorter effective retention if volume is high). Captured as an impl task, not hand-waved.
- No Docker healthcheck (Loki images are minimal); health signal is the `/ready` endpoint, checked in the acceptance walk-through.

---

## Service Configuration: Alloy

**Image:** `grafana/alloy:<v1.x pinned at impl>` · **Ports:** 3110 (UI), 3111 (faro.receiver, localhost) · **mem_limit:** 250M · **user:** `1026:100` + `group_add` (§D8) · **restart:** `unless-stopped`

**`config/alloy/config.alloy` (skeleton — three pipelines):**

```alloy
// ---- 1. Backend logs: container stdout via Docker discovery (Spec FR-48, D8) ----
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers" {
  targets = discovery.docker.containers.targets
  // Canonical label schema (resolves Spec Scenario 2's /plan-deferred label key):
  rule { source_labels = ["__meta_docker_container_name"]            target_label = "container" }
  rule { source_labels = ["__meta_docker_container_label_com_docker_compose_service"] target_label = "compose_service" }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers.output
  labels     = { job = "container-logs" }
  forward_to = [loki.write.default.receiver]
}

// ---- 2. Host system logs (best-effort, Spec FR-48) ----
local.file_match "hostlogs" { path_targets = [{ __path__ = "/var/log/*.log" }] }
loki.source.file "hostlogs" {
  targets    = local.file_match.hostlogs.targets
  forward_to = [loki.write.default.receiver]
}

// ---- 3. Frontend RUM: Faro receiver (Spec FR-49/FR-51, D5) ----
faro.receiver "mneme" {
  server {
    listen_address       = "127.0.0.1"
    listen_port          = 3111
    cors_allowed_origins = [ sys.env("FARO_ALLOWED_ORIGIN") ]   // explicit, never "*"
    api_key              = sys.env("FARO_API_KEY")              // VERIFY attr exists in pinned version (Phase 0)
  }
  output {
    logs   = [loki.write.default.receiver]   // logs + exceptions + events + measurements
    traces = []                              // ← UNWIRED: traces DROPPED (v1.3 boundary, FR-49/Scenario 6)
  }
}

// ---- Sink ----
loki.write "default" {
  endpoint { url = "http://localhost:3100/loki/api/v1/push" }
  // graceful retry/backoff so Alloy does not crash-loop if Loki is down (Spec FR-50)
  // — loki.write buffers + retries by default; WAL persists across Loki restarts.
}
```

**Notes:**
- **Canonical label key = `container`** (plus `compose_service`) — this resolves Scenario 2's deferred label-schema question. `docs/logs-setup.md` documents it; example queries use `{container="..."}`.
- **Traces dropped in code:** `output { traces = [] }` is the literal enforcement of v1.3's APM deferral. The synthetic beacon (Phase 6) sends a trace and confirms nothing lands and nothing errors. A future tracing feature wires this one line.
- **Secrets via `sys.env`** — `FARO_API_KEY` and `FARO_ALLOWED_ORIGIN` come from env (Portainer stack vars / `.env`), so no `envsubst`/sed templating of the config is needed (sidesteps memory `project_dsm_no_envsubst` entirely for Alloy). Loki's config is static.
- **Graceful Loki-down behavior (FR-50):** `loki.write` retries with backoff and a WAL by default — Alloy logs errors and resumes, does not crash-loop. Verified in the acceptance walk-through by cycling Loki.

---

## Grafana Loki datasource (FR-52)

Add to `docker/grafana/provisioning/datasources/datasources.yaml`:

```yaml
  - name: Loki
    type: loki
    uid: loki                  # explicit, per v1.1 datasource-UID determinism
    access: proxy
    url: http://localhost:3100
    jsonData:
      maxLines: 1000
```

The existing `uid: prometheus` datasource is unchanged. The custom Grafana image rebuilds (existing `build-grafana-image` workflow triggers on `docker/grafana/**`), redeploys, and Scenario 7 confirms both datasources are healthy and F001–F003 dashboards render unchanged (NFR-22).

---

## Bind mounts, init script, and the Portainer constraint

Per memory `project_portainer_bind_mounts`, Loki/Alloy config files **cannot** be relative-mounted from the repo — Portainer's workspace lives inside its own container. So `scripts/init-nas-paths.sh` is extended to, on the NAS:

1. **Create** the state dirs: `/volume1/docker/observability/loki/{chunks,tsdb-index,tsdb-cache,compactor,rules}` and `/volume1/docker/observability/alloy/{data}` (exact root path matches the existing F001–F003 convention — verify at impl).
2. **`chown -R 1026:100`** all of the above (DSM admin UID; v1.1) — and document the `synoacltool -del` + `chown` recovery for the ACL restart-loop (memory `project_dsm_acl_recovery`) in `docs/logs-setup.md`, same discipline every bind-mount feature follows.
3. **`curl`** the committed `loki-config.yaml` and `config.alloy` from the repo raw URL to absolute host paths (e.g. `/volume1/docker/observability/loki/loki-config.yaml`), which the compose then mounts read-only. Same pattern F001–F003 use for service configs.

`docker-compose.logs.yml` mounts: config files `:ro`, state dirs `:rw`, and (Alloy) the Docker socket `:ro` + container-log path `:ro` (§D8). State paths and config paths are distinct → no bind-mount masking (v1.1 baked-vs-state, applied to bind-mounted upstream).

---

## Memory budget (logs/RUM subsystem — independent of metrics 600M)

| Service | `mem_limit` | Notes |
|---|---|---|
| Loki | 200M | single-binary, filesystem store; typical footprint well under at homelab volume |
| Alloy | 250M | three pipelines (container logs, host logs, faro receiver) |
| **Total** | **450M** | **≤ 500M logs/RUM cap (Constitution v1.3, Principle IV); 50M headroom** |

The metrics subsystem stays at exactly 600M (untouched). The two caps are tracked separately, never summed into one number (v1.3). If a D5/D8 fallback adds a container (Caddy +40M and/or socket-proxy +20M), the rebalance is pre-specified in those sections and still lands ≤ 500M.

**NFR-18:** if observed logs/RUM memory approaches 70% of 500M, investigate (Loki stream cardinality, Alloy buffer sizing) before raising any limit — and if a raise is genuinely needed, amend the constitution per Principle IV rather than silently exceeding 500M.

---

## Synthetic beacon verification (FR-57 — how F004 proves itself)

F004 closes on a self-generated beacon, not on Mneme telemetry (Spec D7). The mechanism:

A `curl` POST of a hand-built Faro-format JSON payload (a **log** + an **exception** + a **measurement** + a **trace** span) to the receiver. Run through the full edge (DSM HTTPS → Alloy) and, for the negative cases, directly. Four assertions:

1. **Key enforced** — POST **without** `x-api-key` (or wrong key) → rejected (Alloy `api_key`, or the Caddy fallback, returns 401/403); POST **with** the correct key → accepted (2xx).
2. **CORS enforced** — `OPTIONS` preflight with `Origin: <mneme-origin>` → `Access-Control-Allow-Origin: <mneme-origin>`; with any other origin → header absent.
3. **Traces dropped** — the payload's log/exception/measurement land in Loki; the **trace** span does not (no traces output wired); nothing errors.
4. **Accepted signals land** — LogQL query in Grafana (e.g. `{app="mneme-frontend"}` or the agreed RUM label set) returns the log + exception + measurement.

Impl picks `curl` vs. Faro's own test tooling and writes the exact payload + LogQL queries. This is a task, runnable repeatedly, fully within F004's control.

---

## Faro contract block (FR-56 — the F012-unparking artifact)

F004 publishes this into Mneme's `docs/observability.md`. Draft shape (finalized once D5's DSM subdomain fixes the URL):

```markdown
## Faro RUM receiver (provided by nas-observability F004)

- **Endpoint:**  https://<faro-subdomain>.<domain>/collect      ← finalized post-D5 (placeholder until then)
- **Method:**    POST (Faro Web SDK default transport)
- **Auth:**      header `x-api-key: <FARO_API_KEY>`  (value shared out-of-band; lives in nas-observability .env)
- **CORS:**      only `<mneme-frontend-origin>` is allowed (never `*`); other origins are blocked by the browser
- **Accepted signals:** logs, exceptions, events, measurements (web-vitals)
- **Dropped signals:**  traces/spans — APM/Tempo is deferred (Constitution v1.3); the SDK may emit them, they are discarded server-side
- **SDK init (Mneme F012 side):** initializeFaro({ url: <Endpoint>, apiKey: <key>, app: { name: 'mneme-frontend' } })
```

**Timing (Spec D6/D7):** the endpoint URL is gated on D5 standing up the DSM edge. Until then Mneme F012 can integrate against a placeholder URL — the rest of the contract is stable. F004 is not "done" until this block is published (it's the unparking artifact); F004 does **not** wait for Mneme to consume it.

---

## Implementation Phases

Decomposed in detail in [`tasks.md`](./tasks.md) (next). High-level shape:

**0. Pre-flight gates** — F004-unique, all resolvable before any deploy:
   - `docker manifest inspect` to pin exact Loki 3.x / Alloy v1.x tags (F001 lesson: upstream tags occasionally lie).
   - Verify Alloy `faro.receiver` supports `api_key` + `cors_allowed_origins` in the pinned version → confirms D5 needs no Caddy (else take the documented Caddy fallback).
   - `stat` the Docker socket on the DS224+ → confirms the D8 `group_add` GID (else take the socket-proxy fallback).

**1. Bind-mount paths + init script** — extend `init-nas-paths.sh` to create + `chown 1026:100` the Loki/Alloy `/volume1` dirs and `curl` their configs to absolute host paths (Portainer constraint). Document ACL restart-loop recovery in `docs/logs-setup.md`.

**2. Loki deploy + config** — `loki-config.yaml` (single-binary, filesystem, schema v13, `retention_enabled: true`, 7d). Deploy via `docker-compose.logs.yml`. Verify `/ready` and a manual push round-trips.

**3. Alloy backend-log pipeline** — `config.alloy` pipelines 1+2 (container logs via D8 socket mechanism, host logs). Verify Mneme's pino logs + all-container streams query in Grafana → Explore → Loki. Confirm the canonical `container` label.

**4. Grafana Loki datasource** — add to provisioning, rebuild image, redeploy, confirm both datasources healthy + F001–F003 dashboards unregressed (NFR-22).

**5. Faro receiver + edge** — `config.alloy` pipeline 3 (faro.receiver, logs-only output, traces unwired, key + CORS via `sys.env`). Stand up the DSM Application Portal TLS edge (runbook). Wire `.env` / Portainer vars (`FARO_API_KEY`, `FARO_ALLOWED_ORIGIN`).

**6. Synthetic beacon verification** — run the four-assertion beacon (key / CORS / trace-drop / landing). Fully within F004's control; no F012 dependency.

**7. Retention-deletion verification (SEPARATE from the 24h observation)** — short-retention test: temporarily set Loki retention to ~1h, ingest, confirm the compactor deletes expired chunks/index on schedule, restore 7d. This proves the deletion mechanism, which a 24h window structurally cannot (Spec §phase-8). Plus: confirm the size-guard mechanism is wired.

**8. Publish the Faro contract block** into Mneme's `docs/observability.md` (FR-56) — the F012-unparking artifact. Endpoint URL filled in once Phase 5's DSM edge fixes it.

**9. DS224+ deploy + acceptance** — operator-driven walk-through of Spec scenarios 1–10. `diagnose.sh` (extended for the logs/RUM stack) is first-line if anything misbehaves.

**10. 24-hour stability observation** — characterizes **ingestion stability** (Alloy keeps up, receiver responsive, no crash-loop, no memory creep vs. 500M) and **disk-growth rate** (extrapolated to "will 7 days fit under the size guard?"). It does **NOT** characterize retention-deletion (Phase 7 owns that). Diurnal window justified as in F002/F003 (Hyper Backup, day/night Mneme usage).

Phase 0 and Phase 7 are the F004-equivalents of F003's Phase 0 / Phase 5 discipline — verifications that prevent shipping against unverified assumptions (here: upstream capabilities + the retention mechanism, rather than metric names).

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Pinned Alloy version's `faro.receiver` lacks native `api_key` | Medium | Phase 0 verifies. Documented Caddy fallback (§D5) — adds a localhost key/CORS proxy, rebalanced ≤ 500M. No re-plan needed. |
| DSM Docker socket perms differ from `root:root 660` assumption | Medium | Phase 0 `stat`s the socket and sets the exact `group_add` GID. Socket-proxy fallback (§D8) if `group_add` is insufficient or judged too broad. |
| Portainer relative bind mounts silently fail (configs invisible) | Medium — known trap | Init script `curl`s configs to absolute `/volume1` paths (memory `project_portainer_bind_mounts`); compose mounts those absolute paths. Same pattern as F001–F003. |
| DSM ACL restart-loop on the new Loki/Alloy bind mounts | Medium — recurring | `init-nas-paths.sh` pre-creates + `chown`s; `docs/logs-setup.md` documents `synoacltool -del` + `chown` recovery (memory `project_dsm_acl_recovery`). |
| Log volume blows past the size guard before 7 days | Medium | `retention_enabled` + size guard bound disk (whichever binds first); Phase 7 verifies deletion fires; per-stream rate limits in Loki `limits_config` available if a container floods. NFR-21 frames hitting the guard as a volume signal to investigate. |
| Loki stream cardinality explosion (too many label values) | Low–Medium | Canonical label set kept small (`container`, `compose_service`, `job`); JSON fields parsed at query time (`| json`), not promoted to labels. Documented as the labeling discipline in `docs/logs-setup.md`. |
| Grafana image rebuild regresses an F001–F003 dashboard | Low | Existing build-workflow verification + Scenario 7 confirms datasources healthy and dashboards render post-rebuild (NFR-22). |
| Alloy crash-loops when Loki is down | Low | `loki.write` retries with backoff + WAL by default (FR-50); verified by cycling Loki in the acceptance walk-through. |
| DSM Application Portal can't be configured for the Faro subdomain | Low | If the operator hasn't enabled DSM reverse proxy / has no domain, the Caddy fallback (§D5) can terminate TLS directly on a high port; documented as the alternative edge. |
| Contract URL churn after D5 | Low — expected | F012 wires a placeholder until Phase 8 publishes the real URL; the rest of the contract is stable (Spec D6). Honest cross-repo timing, not a surprise. |

---

## Dependencies

**Constitution v1.3.0** ratified (merge `9ac1a2b` on 2026-05-31). v1.3's broadened scope (metrics + logs + RUM), two-subsystem budgets, `3100–3199` range, and APM-deferral-with-trace-dropping are the reasons F004 looks the way it does.

**F001–F003 metrics stack deployed and stable** — the existing 6-service stack, 600M cap, and custom Grafana image are the substrate F004 extends. F004 touches the metrics subsystem only additively (one datasource).

**DSM Application Portal reverse proxy + a domain/cert** — needed for the Faro receiver's HTTPS edge (§D5). One-time NAS-side runbook (carved Principle II exception). If unavailable, the Caddy-direct-TLS fallback applies.

**Mneme `docs/observability.md` exists (or is created)** — F004 publishes the Faro contract block there (FR-56). This is a **write F004 performs/coordinates**, not a blocking pre-req — it's F004's output, the artifact that unparks F012.

**Downstream — Mneme F012 depends on F004 (producer→consumer, Spec D7):**
- F012 is parked at its cross-repo verification gate waiting for F004's live receiver. F004 merging + publishing the contract is what unparks it.
- The **real end-to-end** verification (Mneme's actual frontend telemetry landing in Loki) is **F012's Phase 2 gate**, owned by the Mneme work stream — not duplicated as an F004 close-out coupling. F004 proves the receiver with a synthetic beacon; F012 proves the integration.
