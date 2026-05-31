# Logs & RUM subsystem setup (Feature 004)

NAS-side runbook for the logs/RUM stack — **Grafana Loki** (log aggregation) +
**Grafana Alloy** (collector + Faro receiver). Sister doc to
[`snmp-setup.md`](snmp-setup.md) and [`mneme-setup.md`](mneme-setup.md).

The logs/RUM subsystem deploys as a **separate Portainer stack** from the
metrics stack, from [`docker-compose.logs.yml`](../docker-compose.logs.yml).
It has its own ≤ 500 MB RAM budget (Loki 200M + Alloy 250M = 450M),
independent of the metrics subsystem's 600 MB (Constitution v1.3).

---

## Prerequisites

- The metrics stack (`docker-compose.yml`) is deployed and healthy — Grafana
  is what visualizes logs/RUM, via the baked Loki datasource (`uid: loki`).
- `scripts/init-nas-paths.sh` has been run (it creates + `chown`s the Loki and
  Alloy `/volume1` state dirs and fetches `loki-config.yaml` + `config.alloy`
  to their host paths).

---

## Step 1 — Initialize NAS paths

```bash
sudo bash scripts/init-nas-paths.sh
```

This creates under `/volume1/docker/observability/`:

- `loki/data` (chunks, index, compactor state) — owner `1026:100`, mode 0755
- `alloy/data` (WAL / positions) — owner `1026:100`, mode 0755
- `loki/loki-config.yaml` + `alloy/config.alloy` — fetched from the repo, mode 644

Both services run as the DSM admin UID `1026:100`; the chown is what lets them
write to `/volume1` (DSM 7.3 blocks low/system UIDs there — see the v1.1 UID
restriction). If a container enters a restart loop after a redeploy, this is
almost always DSM's ACLs overriding POSIX permissions:

```bash
# DSM ACL restart-loop recovery (the recurring DS224+ failure mode):
sudo synoacltool -del /volume1/docker/observability/loki/data
sudo synoacltool -del /volume1/docker/observability/alloy/data
sudo chown -R 1026:100 /volume1/docker/observability/{loki,alloy}
```

---

## Step 2 — Generate the Faro API key

The Faro receiver is gated by an API key. Browsers send it as the `x-api-key`
header on every beacon.

```bash
openssl rand -base64 32
```

Save the output — it goes into Portainer in Step 3, and into the contract
block Mneme's frontend (F012) consumes.

---

## Step 3 — Set the logs/RUM stack environment

In Portainer, on the **logs/RUM** stack (not the metrics stack), set two
environment variables:

| Variable | Value |
|---|---|
| `FARO_API_KEY` | the key generated in Step 2 |
| `FARO_ALLOWED_ORIGINS` | `http://192.168.0.8:8080,http://ds224plus.tailda1ab8.ts.net:8080` |

`FARO_ALLOWED_ORIGINS` is the **CORS allow-list** — the exact origins browsers
load Mneme from. **Never `*`.** This NAS has two: the LAN IP (Tailscale off)
and the Tailscale name (Tailscale on). If you add a third access path, add its
origin here. Alloy reads both vars via `sys.env` at runtime — they are never
baked into `config.alloy`.

> ⚠️ **No space after the comma.** Set it exactly as
> `http://192.168.0.8:8080,http://ds224plus.tailda1ab8.ts.net:8080` — Alloy
> does `split(..., ",")`, so a space after the comma would leave a leading
> space on the second origin (`" http://ds224plus…"`). CORS origin matching is
> exact, so that space would **silently block** every Tailscale-origin beacon
> while LAN beacons keep working. No trailing comma either.

---

## Step 4 — Deploy + verify

Deploy the logs/RUM stack in Portainer. Then:

```bash
# Loki ready:
curl -fsS http://localhost:3100/ready          # -> "ready"

# Alloy UI / health (remapped off 12345 to 3110):
curl -fsS http://localhost:3110/-/ready         # -> OK

# Container logs are flowing (Mneme's pino JSON, every container):
#   Grafana -> Explore -> Loki -> {container="<mneme-api-container>"}
```

`scripts/diagnose.sh` covers both new services (container state, declared
ports in use, bind-mount ownership). Loki disk usage is the standalone `du`
check below (§Loki disk-watch).

---

## Receiver posture (deliberate — read this)

This is a **chosen security posture**, documented so it's not mistaken for an
oversight (D5, resolved by the T086 network audit):

- **HTTP, no TLS.** Mneme is served over HTTP on both paths, so a beacon POST
  from an HTTP page to an HTTP receiver has no mixed-content constraint and
  needs no TLS. There is no DSM Application Portal edge, no Tailscale Serve, no
  Caddy, no cert.
- **Receiver binds host interfaces (`0.0.0.0:3111`), not localhost.** There is
  no reverse proxy in front, so it must be directly reachable by the browser.
  Host networking exposes it on both `http://192.168.0.8:3111` (LAN) and
  `http://ds224plus.tailda1ab8.ts.net:3111` (Tailscale) automatically.
- **The API key is the SOLE access gate** — not a second layer behind a proxy.
  Anything on the LAN or tailnet can reach the port; the key is what stops it.
  Acceptable for a single-user, trusted LAN + tailnet.
- **Encryption:** telemetry is plain HTTP. The Tailscale path is WireGuard-
  encrypted at the network layer regardless; the LAN path is plaintext (own
  LAN carrying own error logs to own NAS — fine at this scale). No end-to-end
  TLS, accepted deliberately.
- **Traces are dropped.** The Faro receiver accepts logs, exceptions, events,
  and measurements; the traces output is unwired (APM/Tempo is deferred by
  Constitution v1.3). A future tracing feature wires that one output.

---

## Loki disk-watch (NOT an automatic size cap)

Loki retention is **7-day time retention** (`retention_period: 168h` +
`compactor.retention_enabled: true`) — this part is **automatic**: the
compactor deletes chunks/index older than 7 days on its schedule.

Loki's filesystem store has **no native total-bytes eviction** (unlike
Prometheus' `--storage.tsdb.retention.size`). So protecting the disk against a
log-volume spike is **operator vigilance**, not an automatic cap:

```bash
# Watch Loki's footprint:
du -sh /volume1/docker/observability/loki/data
```

If it grows uncomfortably before 7-day retention reclaims it, the lever is to
**shorten retention** (`retention_period` in `loki-config.yaml`, re-fetch via
`init-nas-paths.sh`, restart Loki) — there is no byte cap that auto-trims.

---

## The Faro contract (for Mneme F012)

F004 publishes the receiver contract into Mneme's `docs/observability.md` — it
is the artifact that unparks F012. Summary of what F004 owns:

- **Endpoints (HTTP, no TLS):**
  - Tailscale (recommended default for remote): `http://ds224plus.tailda1ab8.ts.net:3111/collect`
  - LAN (home): `http://192.168.0.8:3111/collect`
- **Auth:** header `x-api-key: <FARO_API_KEY>`
- **CORS:** only the two origins above (never `*`)
- **Accepted:** logs, exceptions, events, measurements · **Dropped:** traces

F004 does **not** wait for Mneme to consume this; the real end-to-end
verification (Mneme's frontend telemetry landing in Loki) is F012's own gate.

---

## Troubleshooting

- **Alloy can't read the Docker socket** (`permission denied` on
  `/var/run/docker.sock`): confirm the socket is `root:root 660`
  (`stat -c '%U:%G %a' /var/run/docker.sock`) and that the `alloy` service has
  `group_add: ["0"]`. If DSM changed the socket's group, set `group_add` to
  the actual GID.
- **Browser beacons fail CORS** (console error, no `Access-Control-Allow-Origin`):
  the origin the browser used isn't in `FARO_ALLOWED_ORIGINS`. Common case:
  loaded Mneme over Tailscale but only the LAN origin is listed. Both must be
  present.
- **Beacons get 401:** the `x-api-key` header is missing or doesn't match
  `FARO_API_KEY`. Confirm the value matches what Mneme's SDK sends.
- **Alloy crash-loops at start with Loki down:** it shouldn't — `loki.write`
  retries with backoff + WAL. If it does, check `config.alloy` was fetched
  correctly and the `/var/lib/alloy/data` mount is writable (`1026:100`).
- **`loki/data` restart loop after redeploy:** DSM ACLs — run the
  `synoacltool -del` + `chown` recovery in Step 1.
