# Implementation Plan: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-05-31

---

## Technical Context

F004 is the first feature implemented under Constitution v1.3.0, which broadened the platform from metrics-only to metrics + logs + RUM and split Principle IV into two subsystem budgets. It adds a **logs/RUM subsystem** — Grafana Loki + Grafana Alloy — in a separate `docker-compose.logs.yml`, leaving the F001–F003 metrics subsystem untouched except for one additive change to the baked Grafana image (a Loki datasource).

The component count is small (two services), but the substantive work is in three contract surfaces, the same way F003's weight was in *its* contract surfaces:
1. **The Faro receiver's browser-facing edge** — API-key + two-origin CORS enforcement over HTTP on host interfaces (no TLS, no proxy — D5/T086), and the cross-repo contract block that unparks Mneme F012.
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
- The contract's **endpoint URL is known now** (T086 — no TLS edge to stand up): the receiver answers on `http://192.168.0.8:3111` (LAN) and `http://ds224plus.tailda1ab8.ts.net:3111` (Tailscale). No placeholder; the contract publishes once the receiver port is configured.

**Networking:** `network_mode: host` throughout (Principle III). Ports in the v1.3 `3100–3199` logs/RUM band: Loki HTTP **3100**, Loki gRPC **3101** (remapped off upstream 9095 to keep the subsystem contiguous and avoid the Prometheus-adjacent 9090–9099 band), Alloy UI **3110**, Alloy `faro.receiver` **3111** (bound to host interfaces `0.0.0.0` — D5/T086, reachable on LAN + Tailscale).

**User:** Loki and Alloy both run as `user: "1026:100"` (DSM admin UID) because both persist state to `/volume1` bind mounts (v1.1 DSM UID restriction). Alloy additionally needs Docker-socket read access — resolved in §D8 below without giving up the `1026:100` identity.

**Bind mounts (new):** Loki state (chunks + index + compactor working dir), Alloy state (WAL + positions), and read-only config mounts for both. Per the Portainer constraint (memory `project_portainer_bind_mounts`), config files live at **absolute host paths** under `/volume1`, populated by the init script via `curl` — relative mounts from the repo fail because Portainer's workspace is inside its own container.

---

## Constitution Check

Measured against [`constitution.md`](../../.specify/memory/constitution.md) **v1.3.0**.

| Constraint | Status | Notes |
|---|---|---|
| I. Upstream-First, Thin Customization | ✅ Pass | `grafana/loki` + `grafana/alloy` unmodified at pinned versions; config via runtime bind mounts, not baked. Custom image stays Grafana-only. No fork. |
| II. Declarative Configuration | ✅ Pass | `docker-compose.logs.yml`, `loki-config.yaml`, `config.alloy`, and the Loki datasource provisioning all committed. Key + CORS enforcement is declarative in Alloy config (`sys.env`), not clicked in a UI. No TLS edge / reverse proxy to configure (D5/T086 — HTTP receiver on host interfaces), so there's no manual-edge runbook step beyond setting env vars. |
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
│   └── logs-setup.md                   # NEW — bind-mount runbook, receiver posture (HTTP/host-iface/two-origin), API-key gen, disk-watch, contract
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

## D5 (resolved by T086): Faro receiver edge — HTTP, host interfaces, API key + two-origin CORS, NO TLS, NO proxy

**Original assumption (pre-T086):** receiver on localhost behind a reverse proxy enforcing TLS + API key + CORS; proxy placement (DSM Application Portal vs. container) was a `/plan`/Phase-0 branch.

**T086 resolution (2026-05-31) — the TLS-edge problem dissolved.** Operator network reality: Mneme is served over **HTTP**, not HTTPS, on both paths — `http://192.168.0.8:8080` (LAN, Tailscale off) and `http://ds224plus.tailda1ab8.ts.net:8080` (Tailscale on). No public domain, no Let's Encrypt, free-tier Tailscale. Because the Mneme page is **HTTP**, a beacon POST to an HTTP receiver has **no mixed-content constraint and needs no TLS**. Host networking makes the receiver's host port answer on both the LAN IP and the Tailscale name automatically — **no reverse proxy is needed for reachability**. The entire TLS-termination / cert / DSM-Application-Portal / Caddy-for-TLS complexity is eliminated.

**Resolved topology:**

```
Browser (Faro Web SDK, HTTP page at 192.168.0.8:8080 OR ds224plus.tailda1ab8.ts.net:8080)
   │  HTTP POST, x-api-key header, Origin: <whichever path the browser loaded Mneme from>
   ▼
Alloy  faro.receiver  (HOST interfaces :3111, HTTP)  ── enforces api_key + two-origin CORS natively (pending T087)
   │
   ▼
Loki (localhost:3100)   [logs/exceptions/events/measurements only; traces dropped]
```

**Two consequential changes from the original D5:**

1. **Receiver binds host interfaces, NOT localhost.** No proxy → localhost-only would make the receiver unreachable from the browser. It binds the host's accessible interfaces (`0.0.0.0`) so LAN and Tailscale browsers reach it directly on `:3111`. This is a **deliberate security-posture change**: the receiver is directly reachable by anything on the LAN or tailnet, **gated solely by the API key** (the key is the only layer, not a second one behind a proxy). Acceptable for a single-user trusted LAN+tailnet; stated explicitly in `config.alloy` comments and `docs/logs-setup.md` as a chosen posture, not an accident.
2. **CORS carries TWO origins, not one** — `http://192.168.0.8:8080` and `http://ds224plus.tailda1ab8.ts.net:8080`, both explicit, never `*`. From env (`FARO_ALLOWED_ORIGINS`, comma-joined, or two vars) so they stay declarative and out of committed config.

**Encryption posture (documented in `docs/logs-setup.md`):** telemetry is unencrypted at the app layer (HTTP). On the Tailscale path, WireGuard encrypts it at the network layer regardless; on the LAN path it's plaintext — own LAN carrying own error logs to own NAS, fine at single-user scale. No end-to-end TLS, accepted deliberately.

**The ONE remaining branch — T087 (sequence early in Phase 0):** does the pinned Alloy `faro.receiver` enforce `api_key` + `cors_allowed_origins` natively?
- **Yes** → 2-container topology (Loki + Alloy); Alloy binds host interfaces, native key + two-origin CORS; budget Loki 200 / Alloy 250 = 450M. **Done.**
- **No** (api_key absent) → add a tiny **HTTP** Caddy (key-check + two-origin CORS, **no TLS** — much smaller than a TLS-terminating proxy) on host interfaces, proxying to Alloy on `127.0.0.1:3111`; rebalance Loki 200 / Alloy 210 / Caddy 40 = 450M; Caddy gets a `docs/ports.md` row (e.g. 3112). Either way: **no TLS anywhere, host-interface binding, two-origin CORS.**

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
      - /var/run/docker.sock:/var/run/docker.sock:ro    # socket ONLY — API-based collection
```

**Socket-only — no container-log-path mount.** `loki.source.docker` is **API-based**: it streams logs over the Docker API (`GET /containers/<id>/logs`) through the socket. It does **not** read the on-disk json-file log bodies, so the `/volume1/@docker/containers` filesystem mount is **not needed** and is omitted. (That mount belongs to a *different* method — `loki.source.file` tailing the json-file logs directly. F004 uses the API method, so the two are not mixed.) If impl ever switches to file-tailing (e.g. to sidestep socket access entirely), *then* the `/volume1/@docker/containers:ro` mount applies and DSM's Docker data-root being `/volume1/@docker` is the correct, important detail — but that's an explicit alternative, not the default.

**Impl-time verification (Phase 0 gate):** `stat -c '%U:%G %a' /var/run/docker.sock` on the DS224+ to confirm owner/group/mode and the exact GID for `group_add`.

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

# Disk protection = 7d time retention (automatic, above) + operator disk-watch (NOT an auto
# size cap — Loki filesystem store has no native total-bytes eviction). Disk-usage check
# lives in docs/logs-setup.md / diagnose.sh; lever if it grows is shortening retention.
```

**Notes:**
- `retention_enabled: true` is the line that makes the 7d cap actually delete — Loki's default leaves it OFF (unbounded). FR-47. **The 7-day time retention IS automatic; the "size" half is NOT.**
- **The "size guard" is not an automatic total-size cap — be honest about this.** Unlike Prometheus' `--storage.tsdb.retention.size`, Loki's filesystem store has **no native total-bytes eviction**. So the disk protection is really **7-day time retention (automatic) + operator disk-watch (vigilance)**: a documented disk-usage check (in `docs/logs-setup.md` / `diagnose.sh`) the operator monitors, and the lever if it grows is *shortening effective retention*, not a byte cap that auto-trims. At single-operator scale this is fine — but `tasks.md` and the spec's "whichever binds first" must not imply an automatic hard size cap that doesn't exist. The honest framing: time-bounded automatically, size-bounded by watching.
- No Docker healthcheck (Loki images are minimal); health signal is the `/ready` endpoint, checked in the acceptance walk-through.

---

## Service Configuration: Alloy

**Image:** `grafana/alloy:<v1.x pinned at impl>` · **Ports:** 3110 (UI), 3111 (faro.receiver, **host interfaces** — D5/T086) · **mem_limit:** 250M · **user:** `1026:100` + `group_add` (§D8) · **restart:** `unless-stopped`

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

// ---- 3. Frontend RUM: Faro receiver (Spec FR-49/FR-51, D5/T086) ----
faro.receiver "mneme" {
  server {
    listen_address       = "0.0.0.0"   // HOST interfaces, NOT 127.0.0.1 — browsers reach it via LAN + Tailscale (D5/T086)
    listen_port          = 3111
    // TWO origins, explicit, never "*": LAN + Tailscale paths (D5/T086)
    cors_allowed_origins = split(sys.env("FARO_ALLOWED_ORIGINS"), ",")  // e.g. "http://192.168.0.8:8080,http://ds224plus.tailda1ab8.ts.net:8080"
    api_key              = sys.env("FARO_API_KEY")              // VERIFY attr exists in pinned version (T087)
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
- **Secrets/origins via `sys.env`** — `FARO_API_KEY` and `FARO_ALLOWED_ORIGINS` (the two origins, comma-joined → `split()`) come from env (Portainer stack vars / `.env`), so no `envsubst`/sed templating of the config is needed (sidesteps memory `project_dsm_no_envsubst` entirely for Alloy). Loki's config is static.
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

`docker-compose.logs.yml` mounts: config files `:ro`, state dirs `:rw`, and (Alloy) the Docker socket `:ro` only (§D8 — API-based collection, no container-log-path mount). State paths and config paths are distinct → no bind-mount masking (v1.1 baked-vs-state, applied to bind-mounted upstream).

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

F004 publishes this into Mneme's `docs/observability.md`. The URL is **known now** (T086 — no TLS edge to stand up); only the receiver path (`/collect` vs. Alloy's actual default) is impl-confirmed:

```markdown
## Faro RUM receiver (provided by nas-observability F004)

- **Endpoints (HTTP, no TLS):**
    - Tailscale (recommended default for remote): http://ds224plus.tailda1ab8.ts.net:3111/collect
    - LAN (home, Tailscale off):                  http://192.168.0.8:3111/collect
    F012 points the SDK at whichever origin matches how the browser loaded Mneme.
- **Method:**    POST (Faro Web SDK default transport)
- **Auth:**      header `x-api-key: <FARO_API_KEY>`  (value shared out-of-band; lives in nas-observability .env)
- **CORS:**      ONLY these two origins are allowed (never `*`): http://192.168.0.8:8080 and http://ds224plus.tailda1ab8.ts.net:8080
- **Transport:** plain HTTP. Tailscale path is WireGuard-encrypted at the network layer; LAN path is plaintext (single-user, accepted)
- **Accepted signals:** logs, exceptions, events, measurements (web-vitals)
- **Dropped signals:**  traces/spans — APM/Tempo is deferred (Constitution v1.3); the SDK may emit them, they are discarded server-side
- **SDK init (illustrative — exact Faro Web SDK init verified F012-side):**
    initializeFaro({ url: <Endpoint>, app: { name: 'mneme-frontend' }, /* send x-api-key via the transport's requestOptions.headers */ })
```

**What's authoritative vs. illustrative.** The producer-owned, authoritative parts of this contract are the **endpoint**, the **`x-api-key` header name**, the **CORS origin**, and the **accepted/dropped signal classes** — those are the interface F004 owns. The `initializeFaro(...)` snippet is **illustrative only**; the Faro Web SDK typically sets custom headers via the transport's `requestOptions.headers` rather than a top-level `apiKey` field, and the exact init shape is **F012's mechanics, verified F012-side**. The contract fixes *the header to send*, not *how Mneme's SDK sends it* — marked so a snippet mismatch doesn't mislead F012.

**Timing (Spec D6/D7) — RESOLVED by T086:** the endpoint URL is **known now** (no TLS edge to stand up), so there's no placeholder and no post-`/plan` wait — the contract publishes as soon as the receiver port (3111) is configured. F004 is not "done" until this block is published (it's the unparking artifact); F004 does **not** wait for Mneme to consume it.

---

## Implementation Phases

Decomposed in detail in [`tasks.md`](./tasks.md) (next). High-level shape:

**0. Pre-flight gates** — F004-unique, the most consequential task group: **three impl-time verifications branch the topology of everything downstream**, so they run first and in roughly this order (most-branching first):
   - **(a) Browser→receiver reachability + TLS edge — RESOLVED by T086 (2026-05-31): HTTP, no TLS, no proxy.** Mneme is HTTP on both paths (LAN `192.168.0.8:8080`, Tailscale `ds224plus.tailda1ab8.ts.net:8080`); no mixed-content constraint, no cert needed; host networking gives both routes free. The receiver binds host interfaces with a two-origin CORS list and the API key as sole gate. No remaining sub-task here beyond recording the posture.
   - **(b) Alloy `faro.receiver` capability — THE live branch** — verify the pinned version exposes `api_key` + `cors_allowed_origins`. A real branch: **yes** → 2 containers (Alloy enforces natively); **no** → tiny HTTP Caddy (key + two-origin CORS, no TLS) on host interfaces. Settles 2- vs. 3-container topology + the 450M rebalance before any config is written.
   - **(c) `docker manifest inspect`** to pin exact Loki 3.x / Alloy v1.x tags (F001 lesson: upstream tags occasionally lie).
   - **(d) `stat` the Docker socket** on the DS224+ → confirms the D8 `group_add` GID (else the socket-proxy fallback).

**1. Bind-mount paths + init script** — extend `init-nas-paths.sh` to create + `chown 1026:100` the Loki/Alloy `/volume1` dirs and `curl` their configs to absolute host paths (Portainer constraint). Document ACL restart-loop recovery in `docs/logs-setup.md`.

**2. Loki deploy + config** — `loki-config.yaml` (single-binary, filesystem, schema v13, `retention_enabled: true`, 7d). Deploy via `docker-compose.logs.yml`. Verify `/ready` and a manual push round-trips.

**3. Alloy backend-log pipeline** — `config.alloy` pipelines 1+2 (container logs via D8 socket mechanism, host logs). Verify Mneme's pino logs + all-container streams query in Grafana → Explore → Loki. Confirm the canonical `container` label.

**4. Grafana Loki datasource** — add to provisioning, rebuild image, redeploy, confirm both datasources healthy + F001–F003 dashboards unregressed (NFR-22).

**5. Faro receiver exposure + secrets** (no TLS edge to stand up — D5/T086) — `config.alloy` pipeline 3 (faro.receiver on host interfaces `0.0.0.0:3111`, logs-only output, traces unwired, api_key + two-origin CORS via `sys.env`). Wire `.env` / Portainer vars (`FARO_API_KEY`, `FARO_ALLOWED_ORIGINS`). Document the no-TLS/two-origin/host-interface posture in `docs/logs-setup.md`. Add the HTTP Caddy only if T087 forced it.

**6. Synthetic beacon verification** — run the four-assertion beacon (key / CORS / trace-drop / landing). Fully within F004's control; no F012 dependency.

**7. Retention-deletion verification (SEPARATE from the 24h observation)** — short-retention test: temporarily set Loki retention to ~1h, ingest, confirm the compactor deletes expired chunks/index on schedule, restore 7d. This proves the **time-retention deletion mechanism** (automatic), which a 24h window structurally cannot (Spec §phase-8). Plus: install the **operator disk-watch** (disk-usage check in `docs/logs-setup.md` / `diagnose.sh`) — NOT an automatic size cap (Loki has no native total-bytes eviction); the honest protection is time-retention + vigilance, and `tasks.md` states that plainly rather than implying an auto size cap.

**8. Publish the Faro contract block** into Mneme's `docs/observability.md` (FR-56) — the F012-unparking artifact. Endpoint URL filled in once Phase 5's DSM edge fixes it.

**9. DS224+ deploy + acceptance** — operator-driven walk-through of Spec scenarios 1–10. `diagnose.sh` (extended for the logs/RUM stack) is first-line if anything misbehaves.

**10. 24-hour stability observation** — characterizes **ingestion stability** (Alloy keeps up, receiver responsive, no crash-loop, no memory creep vs. 500M) and **disk-growth rate** (extrapolated to "will 7 days fit under the size guard?"). It does **NOT** characterize retention-deletion (Phase 7 owns that). Diurnal window justified as in F002/F003 (Hyper Backup, day/night Mneme usage).

Phase 0 and Phase 7 are the F004-equivalents of F003's Phase 0 / Phase 5 discipline — verifications that prevent shipping against unverified assumptions (here: upstream capabilities + the retention mechanism, rather than metric names).

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Pinned Alloy version's `faro.receiver` lacks native `api_key` | Medium | T087 verifies. Documented HTTP-Caddy fallback (§D5) — adds a host-interface key/CORS proxy (no TLS), rebalanced ≤ 500M. No re-plan needed. |
| DSM Docker socket perms differ from `root:root 660` assumption | Medium | Phase 0 `stat`s the socket and sets the exact `group_add` GID. Socket-proxy fallback (§D8) if `group_add` is insufficient or judged too broad. |
| Portainer relative bind mounts silently fail (configs invisible) | Medium — known trap | Init script `curl`s configs to absolute `/volume1` paths (memory `project_portainer_bind_mounts`); compose mounts those absolute paths. Same pattern as F001–F003. |
| DSM ACL restart-loop on the new Loki/Alloy bind mounts | Medium — recurring | `init-nas-paths.sh` pre-creates + `chown`s; `docs/logs-setup.md` documents `synoacltool -del` + `chown` recovery (memory `project_dsm_acl_recovery`). |
| Log volume fills the disk before 7-day retention reclaims it | Medium | 7-day time retention is automatic; there is **no auto byte-cap** (Loki filesystem store has none). Protection is retention + **operator disk-watch** (Phase 7); levers if it grows: shorten retention, or per-stream rate limits in Loki `limits_config`. Honest framing — size protection is partly vigilance, not an automatic hard cap. |
| Loki stream cardinality explosion (too many label values) | Low–Medium | Canonical label set kept small (`container`, `compose_service`, `job`); JSON fields parsed at query time (`| json`), not promoted to labels. Documented as the labeling discipline in `docs/logs-setup.md`. |
| Grafana image rebuild regresses an F001–F003 dashboard | Low | Existing build-workflow verification + Scenario 7 confirms datasources healthy and dashboards render post-rebuild (NFR-22). |
| Alloy crash-loops when Loki is down | Low | `loki.write` retries with backoff + WAL by default (FR-50); verified by cycling Loki in the acceptance walk-through. |
| Receiver directly reachable on LAN/tailnet (no proxy layer) | Accepted posture | D5/T086: API key is the sole gate; single-user trusted LAN+tailnet. Stated explicitly in config + docs. Not a defect — a chosen, documented posture. |
| Browser uses an origin not in the CORS allow-list | Low | Both operator origins (LAN + Tailscale) are allow-listed; a CORS failure surfaces in the browser console and is diagnosable from the contract block. Add an origin if a third access path appears. |

---

## Dependencies

**Constitution v1.3.0** ratified (merge `9ac1a2b` on 2026-05-31). v1.3's broadened scope (metrics + logs + RUM), two-subsystem budgets, `3100–3199` range, and APM-deferral-with-trace-dropping are the reasons F004 looks the way it does.

**F001–F003 metrics stack deployed and stable** — the existing 6-service stack, 600M cap, and custom Grafana image are the substrate F004 extends. F004 touches the metrics subsystem only additively (one datasource).

**No TLS edge / no domain / no reverse proxy** (D5/T086) — the receiver is HTTP on host interfaces, reachable via LAN + Tailscale through host networking. The only external dependency is the operator's two access origins being known (they are: `192.168.0.8:8080` and `ds224plus.tailda1ab8.ts.net:8080`) so CORS can allow-list them.

**Mneme `docs/observability.md` exists (or is created)** — F004 publishes the Faro contract block there (FR-56). This is a **write F004 performs/coordinates**, not a blocking pre-req — it's F004's output, the artifact that unparks F012.

**Downstream — Mneme F012 depends on F004 (producer→consumer, Spec D7):**
- F012 is parked at its cross-repo verification gate waiting for F004's live receiver. F004 merging + publishing the contract is what unparks it.
- The **real end-to-end** verification (Mneme's actual frontend telemetry landing in Loki) is **F012's Phase 2 gate**, owned by the Mneme work stream — not duplicated as an F004 close-out coupling. F004 proves the receiver with a synthetic beacon; F012 proves the integration.
