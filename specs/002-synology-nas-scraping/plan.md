# Implementation Plan: Synology NAS Scraping & Dashboards

**Feature Branch:** `002-synology-nas-scraping`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-04-24

---

## Technical Context

F002 extends F001's deployed stack with a fifth service and three dashboards. No new custom images — the Grafana image's build context gains three JSON files but stays otherwise unchanged. The heavy lift is not code but platform interfacing: configuring DSM's SNMP agent, walking its MIB tree, writing dashboards whose queries provably map to metrics that exist.

**Runtime & images:**
- `prom/snmp-exporter:v0.28.0` — upstream, Docker Hub, unmodified (Principle I). Pin version verified at implementation time per F001's lesson.
- No new custom images. Grafana image continues to be our only GHCR-published artifact; its build context gains three dashboard JSONs.
- Existing F001 images and versions all unchanged.

**DSM-side prerequisite:** SNMP enabled on the NAS via `docs/snmp-setup.md` runbook. Carved out of Principle II as the second documented manual step (the first being F001's SNMP-adjacent DSM enablement — wait, no, F001 didn't enable SNMP; that's F002's job exclusively).

**Networking:** `network_mode: host` throughout (Principle III). SNMP exporter on port 9116 (already reserved in F001's `docs/ports.md`).

**User:** `user: "1026:100"` on the SNMP exporter from day one (constitution v1.1 Platform Constraints §DSM UID restriction — no rediscovery).

**Bind mounts:** `/volume1/docker/observability/snmp_exporter/` — rendered `snmp.yml` lives here, populated by the init script from a committed template plus a local `.community` secret file (see §Community string handling).

**Carry-overs from F001 as first-class F002 deliverables:**
- `scripts/diagnose.sh` — built first so it's available for F002's own Phase 8 if anything goes sideways.
- GHA action Node.js 24 migration — landed before the SNMP work, to avoid pinning an unrelated blocker to a feature deploy.
- Multi-arch Grafana image — deferred per spec D6.

---

## Constitution Check

Measured against all of [`constitution.md`](../../.specify/memory/constitution.md) v1.1.0 principles and Platform Constraints that apply.

| Constraint | Status | Notes |
|------------|--------|-------|
| I. Upstream-First, Thin Customization | ✅ Pass | `prom/snmp-exporter` unmodified at pinned version. No new custom image. No forks. |
| II. Declarative Configuration | ✅ Pass | `snmp.yml.template` committed; real config rendered by init script from template + local `.community` file; runbook captures the one-time DSM SNMP enablement. |
| III. Host Networking by Default | ✅ Pass | `network_mode: host`; port 9116 was already reserved in `docs/ports.md` from F001 — this PR claims it. Scrape target `localhost:9116`. |
| IV. Resource Discipline | ✅ Pass | `mem_limit: 40M` on snmp-exporter; total stack allocation 600M (hits the cap exactly). SNMP scrape_interval 60s — respects NAS subsystem (see §D3 validation). |
| V. Silent-by-Default Alerting | N/A | No alerts shipped in F002. |
| v1.1 §DSM UID restriction on /volume1/ | ✅ Pass | snmp-exporter runs as `user: "1026:100"` from the start; bind-mount chowned to match in init script. |
| v1.1 §Separate baked config from persisted state | ✅ Pass | Three NAS dashboards bake into `/etc/grafana/dashboards/` (alongside F001's `stack-health.json`). No baked content lives under `/var/lib/grafana`. |
| v1.1 §Grafana datasource UIDs must be explicit | ✅ Pass | All three new dashboards reference `datasource.uid: "prometheus"` (matches F001's provisioned UID). Traceability table enforces this at authoring time. |

**Violations:** none.

---

## Project Structure

### Files introduced by this feature

```
nas-observability/
├── config/
│   └── snmp_exporter/
│       └── snmp.yml.template              # walkgen output, community-string placeholder
│
├── docker/
│   └── grafana/
│       └── dashboards/
│           ├── nas-overview.json          # NEW — flat, alongside stack-health.json
│           ├── storage-volumes.json       # NEW
│           └── network-temperature.json   # NEW
│
├── scripts/
│   └── diagnose.sh                        # NEW — one-command stack diagnostic dump
│
├── docs/
│   └── snmp-setup.md                      # NEW — DSM SNMP enablement + walkgen runbook
│
└── specs/
    └── 002-synology-nas-scraping/
        ├── spec.md
        ├── plan.md                        # this file
        └── tasks.md                       # generated next from this plan
```

### Files modified

- `docker-compose.yml` — new `snmp-exporter` service
- `config/prometheus/prometheus.yml` — new `synology` scrape job with 60s/30s timing
- `docs/ports.md` — claim the 9116 reservation
- `scripts/init-nas-paths.sh` — extended: create snmp_exporter bind-mount dir; render `snmp.yml` from template via `envsubst` using `.community` file
- `.github/workflows/build-grafana-image.yml` — Node.js 24 action version bumps
- `.env.example` — NEW key: `SYNOLOGY_SNMP_COMMUNITY` documented as a tripwire (real secret lives outside `.env`, see §Community string handling)
- `docs/setup.md` — append cross-reference to `docs/snmp-setup.md` for SNMP enablement
- `docs/deploy.md` — minor: add "bumping the SNMP scrape config" to update flows

### What this feature does NOT introduce

- A custom SNMP exporter image (upstream `prom/snmp-exporter` stays untouched; custom images remain a Grafana-only exception).
- Alertmanager or alert rules (dedicated alerting feature).
- UPS monitoring (future dedicated feature).
- Multi-arch Grafana image (deferred per spec D6).

---

## Service Configuration: SNMP Exporter

### Compose entry

**Image:** `prom/snmp-exporter:v0.28.0`
**Host port:** 9116
**Memory limit:** 40M (see Spec D5 for budget math)
**User:** `1026:100` (DSM admin; v1.1 Platform Constraint)
**Restart policy:** `unless-stopped`
**Container entrypoint:** default (the binary reads `/etc/snmp_exporter/snmp.yml` by convention)

**Volumes:**
- `/volume1/docker/observability/snmp_exporter/snmp.yml:/etc/snmp_exporter/snmp.yml:ro`

**Healthcheck:**
```yaml
healthcheck:
  test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9116/-/ready"]
  interval: 30s
  timeout: 3s
  start_period: 10s
  retries: 3
```

Mirrors F001's cAdvisor healthcheck pattern. `--port` override is not needed — snmp-exporter's default port matches our 9116 target. If it ever didn't, the healthcheck-port-mismatch gotcha from F001 T016 would bite again; recorded in `docs/setup.md` troubleshooting.

### Prometheus scrape job

Added to `config/prometheus/prometheus.yml` alongside the existing three jobs:

```yaml
  - job_name: synology
    scrape_interval: 60s
    scrape_timeout: 30s
    metrics_path: /snmp
    params:
      module: [synology]
    static_configs:
      - targets: ['localhost']  # target the NAS itself; exporter rewrites via relabel
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9116
```

This is snmp_exporter's idiomatic scrape-path pattern: Prometheus hits `/snmp?target=<nas-ip>&module=synology`, the exporter performs the SNMP walk against `<nas-ip>`, translates the response, and returns Prometheus metrics. `localhost` as target is fine because we're host-networking and querying the local SNMP agent.

---

## SNMP Configuration Design

### D3 validation — scrape timing, actually measured

Spec D3 committed to `scrape_interval: 60s` and `scrape_timeout: 30s`. That's defensible *a priori*. Plan ensures it's right *empirically* before the compose goes live.

**Validation procedure (executed before FR-19 writes the scrape job):**

1. After the walkgen runs against the DS224+ (§Walkgen), run the exporter locally against its own host:
   ```bash
   docker run --rm --network host \
     -v /volume1/docker/observability/snmp_exporter/snmp.yml:/etc/snmp_exporter/snmp.yml:ro \
     prom/snmp-exporter:v0.28.0 &
   ```
2. Issue a representative scrape:
   ```bash
   time curl -s 'http://localhost:9116/snmp?target=localhost&module=synology' > /dev/null
   ```
3. Record the `real` time. Run 5 consecutive scrapes 15 seconds apart; record the range.

**Interpretation thresholds:**

| Observed walk (5-sample max) | Action                                               |
|------------------------------|------------------------------------------------------|
| < 3 seconds                  | Consider tightening `scrape_timeout` to 10s (faster failure detection). Keep `scrape_interval: 60s`. |
| 3–10 seconds                 | 30s timeout is correct (~3–10× headroom). Commit as-is. |
| 10–25 seconds                | 30s still works but is close. Review `snmp.yml` for over-broad walks; prune OIDs we don't dashboard. |
| > 25 seconds                 | Budget violation. `snmp.yml` is pulling too much. Must prune OIDs before compose commit. Do NOT push a 60s-interval job with walk approaching timeout — cascading failures ensue. |

**Record in the PR description:** actual observed walk duration and the chosen `scrape_timeout`. This is a one-time measurement that doesn't need re-running unless the MIB tree changes (DSM major upgrade).

**Subsystem-load check (NFR-10):** after the job is live, the Stack Health dashboard's Scrape Duration panel should show the `synology` job as a stable line, not a climbing one. A climbing line = leak (either in exporter or in NAS SNMP daemon); investigate.

### Walkgen (§D2 primary path)

Procedure documented in `docs/snmp-setup.md`. High-level:

```bash
# On the NAS, with SNMP enabled and MIB files available:
docker run --rm -v /volume1/docker/observability/snmp_exporter:/out \
  -w /out prom/snmp-exporter:v0.28.0-generator \
  generator generate \
    --fail-on-parse-errors \
    --snmp-mibs=/usr/share/snmp/mibs \
    --module=synology \
    --output=/out/snmp.yml.raw
```

(Exact invocation validated at implementation; the generator image tag and flags have shifted between snmp_exporter minor versions.)

**Post-walk review:**
1. Open `snmp.yml.raw`. Expected size: ~500–2000 lines depending on DS224+ MIB coverage.
2. Remove OIDs the three dashboards will not consume (keeps scrape tight for D3's walk duration).
3. Verify all remaining OIDs are ones we'll reference in a panel (§D4 traceability table).
4. Templatize the community string: replace the literal `community:` value with `${SYNOLOGY_SNMP_COMMUNITY}`.
5. **Strip v3-only fields from the `auths` block if walkgen produces them.** The generator may emit `security_level`, `auth_protocol`, `priv_protocol` — all SNMPv3 constructs that are irrelevant to our chosen v2c (Spec D1). The auth block should reduce to just `community` and `version: 2`; any remaining v3 field is noise that obscures the actual config.
6. Save as `config/snmp_exporter/snmp.yml.template`. Commit.

**Fallback per spec D2:** if walkgen tooling blocks F002 progress (MIB files missing, generator version misalignment, network issues reaching the MIB registry), use `wozniakpawel/synology-grafana-prometheus-overly-comprehensive-dashboard`'s snmp.yml as a temporary scaffold. Template its community line the same way, commit with a `TODO: replace with walkgen output` note at the top of the file, open a follow-up issue to swap it.

### Community string handling (§D1 mechanism)

Spec D1 surfaced the constraint: **snmp_exporter doesn't natively expand env vars in `snmp.yml`.** Plan picks the approach: **render on the NAS side via `envsubst` in the init script, from a local `.community` secret file.**

**Flow:**

1. Operator, once per NAS, writes the community string to a local file:
   ```bash
   # Over SSH on the NAS (documented in docs/snmp-setup.md):
   sudo bash -c 'echo "chosen-community-string" > /volume1/docker/observability/snmp_exporter/.community'
   sudo chmod 600 /volume1/docker/observability/snmp_exporter/.community
   sudo chown 1026:100 /volume1/docker/observability/snmp_exporter/.community
   ```
2. `scripts/init-nas-paths.sh`, when it gets to the snmp_exporter section:
   - Verifies `.community` exists and is non-empty. If not, emits an **inline recovery snippet** (not just a doc pointer) so the common "forgot to populate `.community`" case is a one-screen fix, then exits non-zero:
     ```
     ERROR: SNMP exporter config cannot be rendered — /volume1/docker/observability/snmp_exporter/.community is missing or empty.

     To fix (one-time, per NAS):
       sudo mkdir -p /volume1/docker/observability/snmp_exporter
       sudo bash -c 'echo "<your-community-string>" > /volume1/docker/observability/snmp_exporter/.community'
       sudo chmod 600 /volume1/docker/observability/snmp_exporter/.community
       sudo chown 1026:100 /volume1/docker/observability/snmp_exporter/.community

     Then re-run this script. Full context in docs/snmp-setup.md §Step 3.
     ```
   - Curls `snmp.yml.template` from the repo's raw URL.
   - Reads `.community` into a local variable.
   - Renders via `sed` (not `envsubst` — DSM's shell doesn't ship `gettext` by default; discovered during Phase 3 T039):
     ```
     sed 's|${SYNOLOGY_SNMP_COMMUNITY}|'"$community"'|g' snmp.yml.template > snmp.yml
     ```
     Sed treats `$` as literal when followed by `{`, matches the template token, and substitutes without needing a separate env-var layer. Works identically on GNU sed (DSM) and BSD sed (macOS dev shells).
   - chowns 1026:100, chmods 644.
3. The compose service bind-mounts the rendered `snmp.yml`. The container never sees the template or the env var.

**Why this mechanism vs. the alternatives:**

- **Why not entrypoint override with envsubst in-container?** Would require building a custom snmp-exporter image (violates Principle I). `prom/snmp-exporter` is a distroless-ish image that doesn't include `envsubst` out of the box, so we can't cleanly wrap its entrypoint without a layer. (Similarly, DSM's own shell doesn't ship `envsubst` — the init script uses `sed` instead; see rendering step above.)
- **Why not pass community via Portainer env var + container entrypoint rendering?** Same reason — no envsubst in the container.
- **Why not commit a placeholder community string and let the operator edit `snmp.yml` in place on the NAS?** Breaks Principle II — config becomes NAS-local state rather than derivable from repo + init script.
- **Why a file and not Portainer env vars feeding an init container?** Compose init-container patterns are flaky under DSM's Compose v2; keeping the rendering in the init script (which we already run over SSH) is simpler and one fewer moving part.

**Trade-off:** the operator must create `.community` once per NAS, documented as a one-time SSH action in `docs/snmp-setup.md`. Modest friction; matches the pattern F001 established for `.env`-but-on-the-NAS.

### `snmp.yml.template` structure

After walkgen and post-walk review, the template resembles:

```yaml
auths:
  public_v2:
    community: ${SYNOLOGY_SNMP_COMMUNITY}
    version: 2

modules:
  synology:
    walk:
      - 1.3.6.1.2.1.1         # system info (sysDescr, sysUpTime, sysName)
      - 1.3.6.1.2.1.2.2        # interfaces table
      - 1.3.6.1.4.1.6574.1     # Synology synoSystem
      - 1.3.6.1.4.1.6574.2     # synoDisk
      - 1.3.6.1.4.1.6574.3     # synoRaid
      - 1.3.6.1.4.1.6574.4     # synoUPS (harmless even if no UPS; returns empty)
      - 1.3.6.1.4.1.6574.5     # synoDiskPerformance
      # ... (final list from walkgen post-review)
    metrics:
      # Populated by walkgen; each entry maps an OID to a Prometheus metric.
      - name: synology_system_status
        oid: 1.3.6.1.4.1.6574.1.1.0
        type: gauge
        # ...
```

Specific OIDs and metric names validated in tasks.md against the walkgen output from *this* DS224+.

---

## Dashboards

### D4 traceability discipline

**No dashboard panel is written until its data source is confirmed.** For each panel across the three dashboards, we build a table:

| Dashboard       | Panel title                  | Metric (PromQL)                                         | SNMP OID                         | Walkgen line # |
|-----------------|------------------------------|---------------------------------------------------------|----------------------------------|----------------|
| NAS Overview    | CPU usage (%)                | `100 - synology_cpu_idle_ratio`                         | `1.3.6.1.4.1.6574.1.1.0` (example) | TBD          |
| NAS Overview    | RAM usage (%)                | `(1 - synology_memory_free_bytes / synology_memory_total_bytes) * 100` | `1.3.6.1.4.1.6574.1.5.x` | TBD          |
| NAS Overview    | Disk usage (%) aggregate     | `avg(synology_volume_used_bytes / synology_volume_total_bytes)` | `1.3.6.1.4.1.6574.3.x`  | TBD          |
| NAS Overview    | System temperature           | `synology_system_temperature_celsius`                   | `1.3.6.1.4.1.6574.1.2.0`         | TBD          |
| NAS Overview    | CPU over time                | same as CPU usage, as time series                       | same                             | TBD          |
| NAS Overview    | RAM over time                | same as RAM usage, as time series                       | same                             | TBD          |
| NAS Overview    | Load average (1/5/15)        | `synology_cpu_load1 / synology_cpu_load5 / synology_cpu_load15` | `1.3.6.1.4.1.6574.1.3.x` | TBD       |
| Storage & Vol   | Per-volume usage (gauge)     | `synology_volume_used_bytes / synology_volume_total_bytes` by volume | `1.3.6.1.4.1.6574.3.1.x` | TBD  |
| Storage & Vol   | Per-volume free GB           | `synology_volume_free_bytes / 1024^3` by volume         | same                             | TBD            |
| Storage & Vol   | SMART health per disk (stat) | `synology_disk_status` labeled by disk                  | `1.3.6.1.4.1.6574.2.1.x`         | TBD            |
| Storage & Vol   | Read/write IOPS per volume   | `rate(synology_volume_reads_total[5m])` etc.            | `1.3.6.1.4.1.6574.5.x`           | TBD            |
| Storage & Vol   | Storage pool status          | `synology_raid_status` labeled by pool                  | `1.3.6.1.4.1.6574.3.x`           | TBD            |
| Network & Temp  | Per-interface throughput in  | `rate(ifHCInOctets[5m]) * 8` by iface                   | `1.3.6.1.2.1.31.1.1.1.6.x`       | TBD            |
| Network & Temp  | Per-interface throughput out | `rate(ifHCOutOctets[5m]) * 8` by iface                  | `1.3.6.1.2.1.31.1.1.1.10.x`      | TBD            |
| Network & Temp  | Per-disk temperature (stat)  | `synology_disk_temperature_celsius` by disk             | `1.3.6.1.4.1.6574.2.1.x`         | TBD            |
| Network & Temp  | Per-disk temperature (time)  | same as above, as time series                           | same                             | TBD            |
| Network & Temp  | System temperature (time)    | `synology_system_temperature_celsius`                   | `1.3.6.1.4.1.6574.1.2.0`         | TBD            |
| Network & Temp  | Fan speed (if exposed)       | `synology_system_fan_rpm` — may not exist on DS224+     | model-dependent                  | TBD — drop panel if no line |

**Walkgen line # is filled in during tasks.md work** by running the walkgen and confirming each OID is in the output. Any panel whose OID is NOT in walkgen output gets deleted (not shipped with "no data" guaranteed). This is the anti-pattern defense: dashboards that look alive but actually show nothing for three months because we copy-pasted queries against OIDs DS224+ doesn't expose.

**Exact PromQL is authored during dashboard JSON creation** — the column above shows intent, not final form. Walkgen output determines the actual metric names (snmp_exporter auto-generates them from OID descriptions).

### Per-dashboard composition

**NAS Overview** — high-level "is the NAS healthy" view, 7 panels:
- Row 1 (stats, h=4): CPU %, RAM %, Disk agg %, System temp
- Row 2 (time series, h=8): CPU over time | RAM over time
- Row 3 (time series, h=5): Load average (1/5/15m)

Dashboard metadata: title `NAS Observability — Overview`, tags `[synology, overview]` (see §Dashboard tag convention), time range default `last 6 hours`, refresh `30s`.

**Storage & Volumes** — "how are my disks and volumes doing," 5 panels:
- Row 1 (gauge x N, h=6): Per-volume usage (one gauge per volume)
- Row 2 (stat x N, h=4): SMART health per disk
- Row 3 (time series, h=8): Read/write IOPS per volume
- Row 4 (stat, h=4): Storage pool status

Tags: `[synology, storage]`.

**Network & Temperature** — "thermal + network throughput," 6 panels:
- Row 1 (time series, h=8): Per-interface throughput in/out (stacked or dual-axis)
- Row 2 (stat x N, h=4): Per-disk temperature (one stat per disk)
- Row 3 (time series, h=8): Per-disk temperature over time
- Row 4 (time series, h=5): System temperature + fan speed (if exposed)

Tags: `[synology, network]`.

### Authoring workflow

Matches F001's: local Grafana with `editable: true`, iterate in the UI against a test Prometheus pointed at the live NAS (or at a saved SNMP exporter response), export JSON, commit under `docker/grafana/dashboards/`. Final committed JSON has `editable: false` per F001's lockdown pattern.

Each committed JSON MUST:
- Declare `datasource.uid: "prometheus"` on every panel target (v1.1 Platform Constraint).
- Set `editable: false`.
- Carry tags per the §Dashboard tag convention below.
- Use `uid` field matching the dashboard slug (e.g., `nas-overview`, `storage-volumes`, `network-temperature`).

### Dashboard tag convention

Every committed dashboard carries exactly two tags, in order, forming a two-tier schema that scales across features without restructuring:

- **Tier 1 (source / consumer):** who produces the metrics the dashboard consumes.
  - `stack-health` — the observability stack observing itself (F001)
  - `synology` — the NAS itself via SNMP (F002)
  - `<app-slug>` — future per-application tags (e.g., `mneme`, F003+)
- **Tier 2 (facet category):** what aspect of Tier 1 the dashboard covers.
  - `overview` — high-level health-at-a-glance
  - `storage` — disks, volumes, pools, IOPS
  - `network` — interfaces, throughput, thermal
  - `api` — request rate, latency, error rate (future app dashboards)
  - `meta` — meta-health view of the observability stack itself

Applied to current and planned dashboards:

| Dashboard                         | Feature | Tags                       |
|-----------------------------------|---------|----------------------------|
| Stack Health                      | F001    | `[stack-health, meta]`     |
| NAS Overview                      | F002    | `[synology, overview]`     |
| Storage & Volumes                 | F002    | `[synology, storage]`      |
| Network & Temperature             | F002    | `[synology, network]`      |
| (example) Mneme API Health        | F003+   | `[mneme, api]`             |

**Why this convention:** Grafana's browser filters on tags directly; a two-tier scheme gives operators two independent axes (consumer + facet) without the tag soup that accumulates from ad-hoc slugs. F001's existing `[stack-health, meta]` already aligned with this; codifying it now prevents F003's first dashboard from drifting with a different pattern.

**Note on spec alignment:** FR-20 in the spec used `nas-overview` as an example Tier-2 tag — that's a dashboard slug, not a category. The plan's convention refines it to `overview`. This is a plan-level tightening of the spec's example, not a contradiction of its intent.

---

## Operational Tooling

### `scripts/diagnose.sh` design

Per FR-26 and Scenario 9, one-command dump with five sections in order:

```
============================================================
 nas-observability: diagnose
============================================================

[1/5] Container states
  NAME             STATE                       IMAGE                  UPTIME
  prometheus       Up (healthy)                 prom/prometheus:...    2h14m
  grafana          Up                           ghcr.io/.../grafana    2h14m
  cadvisor         Restarting (exit 1)          cadvisor:v0.49.1       12s ago
  ...

[2/5] Recent logs (last 20 lines per service)
  --- prometheus ---
  ... last 20 lines ...
  --- grafana ---
  ...

[3/5] Memory / CPU snapshot
  Output of `docker stats --no-stream` filtered to stack services.
  Total observed: X MiB / 600 MiB cap.

[4/5] Bind mount ownership
  /volume1/docker/observability/prometheus/data      drwxr-xr-x  1026:100  (OK)
  /volume1/docker/observability/prometheus/prometheus.yml  -rw-r--r--  1026:100  (OK)
  /volume1/docker/observability/grafana/data         drwxr-xr-x  1026:100  (OK)
  /volume1/docker/observability/snmp_exporter/snmp.yml  -rw-r--r--  1026:100  (OK)
  /volume1/docker/observability/snmp_exporter/.community  -rw-------  1026:100  (OK, 600)

[5/5] Declared port in-use check
  3030 grafana        listening  (expected: grafana)           OK
  8081 cadvisor       listening  (expected: cadvisor)          OK
  9090 prometheus     listening  (expected: prometheus)        OK
  9100 node_exporter  listening  (expected: node-exporter)     OK
  9116 snmp-exporter  listening  (expected: snmp-exporter)     OK

============================================================
Status: DEGRADED — cadvisor in restart loop (exit 1)
============================================================
```

**Design choices:**
- Plain text, not JSON. JSON mode is deferred unless we ever need machine consumption.
- Color codes (red/yellow/green) if stdout is a TTY; falls back to plain suffixes (`OK` / `WARN` / `ERR`) if piped.
- Exit code: 0 if all services `Up` and healthy, 1 if any service restarting/exited, 2 if Docker isn't running or the script can't determine state.
- Port-in-use check cross-references `docs/ports.md` implicitly by hard-coding the expected service-per-port table (kept in sync with `docs/ports.md` — if they drift, diagnose's output is the failing proxy).
- Runs in < 10 seconds (NFR-11). No `docker logs --since=...` heuristics that could scan large histories.

**Special-case reporting — SNMP exporter not yet bootstrapped:** Section 4 (bind mount ownership) treats missing `snmp_exporter/snmp.yml` + missing `.community` as a distinguishable state rather than a generic "file not found":
```
  /volume1/docker/observability/snmp_exporter/snmp.yml       MISSING
  /volume1/docker/observability/snmp_exporter/.community     MISSING
  → SNMP exporter config not rendered — .community missing (see docs/snmp-setup.md §Step 3).
```
One clear diagnosis from one command. The arrow-prefixed line is the actionable summary; the two MISSING lines are the evidence. Same pattern applies to any future service that requires a local secret to bootstrap.

Script is `set -euo pipefail` but wraps each section in a function so one section's failure doesn't stop the others (partial diagnostic is better than none).

### GHA action Node.js 24 migration

Exact version pins resolved in `tasks.md` by verifying at migration time which major version of each action has Node.js 24 support. Tentative targets (confirm via action release notes before merging):

| Action                        | F001 (Node 20)         | F002 target     | Verify                                         |
|-------------------------------|------------------------|-----------------|-----------------------------------------------|
| `actions/checkout`            | `v4`                   | `v5`            | Release notes confirm Node 24                 |
| `docker/setup-buildx-action`  | `v3`                   | `v4` (likely)   | Release notes                                  |
| `docker/login-action`         | `v3`                   | `v4` (likely)   | Release notes                                  |
| `docker/build-push-action`    | `v6`                   | `v7` (likely)   | Release notes                                  |

One PR, one commit, path filters unchanged, tags unchanged. First run post-merge validates — watch it immediately (F001 T017 pattern).

---

## Documentation

### `docs/snmp-setup.md` — outline

- **Prerequisites**: F001 stack is deployed and running.
- **Step 1: Enable SNMP on DSM**. Control Panel → Terminal & SNMP → SNMP tab → enable SNMPv2c; set community string (any string you like — it's more like a namespace than a password on a LAN); save. Screenshot/step-by-step.
- **Step 2: Verify SNMP is reachable**. From NAS SSH: `snmpwalk -v2c -c <community> localhost .1.3.6.1.4.1.6574 | head`. Expected: Synology OIDs returning. If not, check Step 1.
- **Step 3: Store the community string on the NAS**. `sudo bash -c 'echo "<community>" > /volume1/docker/observability/snmp_exporter/.community'` + `chmod 600` + `chown 1026:100`.
- **Step 4: (First-time walkgen only, optional)** For forks regenerating `snmp.yml` for a different Synology model — running the generator on the NAS.
- **Step 5: Re-run init script**. `sudo bash /tmp/init-nas-paths.sh`. Expected output shows snmp_exporter path + rendered snmp.yml.
- **Step 6: Redeploy stack in Portainer** — pull + redeploy; expect fifth container to appear.
- **Verification**: `sudo bash scripts/diagnose.sh` shows all five services healthy; Prometheus `/targets` shows the synology job UP.
- **Troubleshooting**: community string mismatch, snmpwalk timeouts, generator fails on MIB parse errors, fallback to community snmp.yml.

### `docs/setup.md` additions

Short cross-reference added: "For SNMP-based scraping of Synology-specific metrics (shipped in F002), see [`docs/snmp-setup.md`](snmp-setup.md)." Placed under the existing "What F001 does not ship" note — matches the layout we established.

### `docs/deploy.md` additions

New bullet under "Flows": **Updating `snmp.yml`**. If OIDs change (DSM major upgrade, or we prune/expand the walked set), edit the template in the repo, commit, re-run init script on the NAS, and restart the snmp-exporter container to re-read the mounted file.

---

## Implementation Phases

Decomposed in detail in [`tasks.md`](./tasks.md). High-level shape (explicitly ordered):

1. **Operational tooling first** — `scripts/diagnose.sh` + GHA Node.js 24 action bumps. Lands before the SNMP work so diagnose.sh is available for F002's own Phase 8, and the GHA migration is out of the way.
2. **SNMP runbook + walkgen** — write `docs/snmp-setup.md`, operator executes it to enable SNMP + capture community string + produce walkgen output. Output committed as `config/snmp_exporter/snmp.yml.template`.
3. **D3 validation** — run the walk through snmp-exporter locally on the NAS, record duration, confirm 30s timeout is appropriate.
4. **Traceability table construction** — for each of the ~18 planned panels, fill in the walkgen line # column. Drop any panel whose OID isn't in walkgen output.
5. **Compose, scrape, init-script wiring** — add snmp-exporter service to compose, add synology scrape job, update init script for `.community` handling + snmp.yml rendering, update ports.md.
6. **Dashboard authoring** — three dashboards authored in local Grafana against a test Prometheus, iterated in UI, exported, committed with `editable: false` + explicit datasource.uid.
7. **DS224+ deploy + acceptance** — redeploy stack via Portainer, walk through F002 scenarios 1–10, use `diagnose.sh` if anything is off.
8. **24-hour observation** — confirm NFR-9 (stable scrape duration over time) and NFR-10 (no subsystem-load pattern on the NAS).

Phase 1's early landing is deliberate: historically, most F001 pain happened in Phase 8 when the baseline tooling didn't yet exist. F002 inverts that.

---

## Risks

| Risk                                                                 | Likelihood | Mitigation                                                              |
|----------------------------------------------------------------------|------------|-------------------------------------------------------------------------|
| `snmp_exporter generator` tooling fails (missing MIBs, version misalignment) | Medium | Fallback to community `snmp.yml` per spec D2, committed with a `TODO` header |
| Observed walk duration exceeds 30s timeout                           | Low        | Prune `snmp.yml` walked set down to what the three dashboards actually consume; re-time |
| GHA Node.js 24 migration breaks the workflow                         | Low–Medium | First post-merge run is watched per F001 T017 discipline; hotfix PR rolls back single action if needed |
| `40M mem_limit` on snmp-exporter proves tight                        | Low        | F001 Spec D2 precedent: trim from cAdvisor (30M observed, 90M limit → 60M is defensible) |
| Dashboard panels show "no data" because OID isn't exposed on DS224+  | Low (if discipline holds) | Traceability table catches this before JSON is committed; any panel without a confirmed walkgen line is dropped |
| Community string accidentally committed to repo                      | Low        | `.community` lives outside the repo; only template with `${SYNOLOGY_SNMP_COMMUNITY}` placeholder is committed; `.gitignore` covers `*.community` as belt-and-suspenders |
| Init script fails when `.community` doesn't exist                    | Expected (by design) | Clear error message points to `docs/snmp-setup.md` Step 3; re-run after fixing |
| DSM upgrade changes the SNMP OID tree                                | Low (rare) | Re-run walkgen, diff against committed template, adjust dashboards referencing changed OIDs |
| Phase 8 surfaces a new DSM quirk not in F001's memory system          | Low (hopefully) | Nine of F001's fixes are now constitutional constraints or documented troubleshooting; if a new one appears, add to memory + setup.md |

---

## Dependencies

**Feature 002 depends on:**

- **Feature 001 complete** — the F001 stack must be deployed and running. F002 extends it; doesn't replace it.
- **Constitution v1.1.0** — F002 cites the three v1.1 Platform Constraints as givens. Constitution at v1.0 would be missing the DSM UID restriction and baked-vs-state constraints, forcing rediscovery in the plan.
- **DSM 7.3 SNMP agent** — shipped with DSM itself, enabled via Control Panel. No third-party dependency.
- **snmp_exporter generator image** — `prom/snmp-exporter:v0.28.0-generator` or similar; verify at walkgen time.

**Downstream features depend on F002:**

- **Alerting feature** (unscheduled) — NAS-level alert rules (disk degraded, temperature sustained, volume near-full) depend on F002 exposing the metrics. F002 is a prerequisite but doesn't ship the alerts themselves.
- **F003 Mneme scraping** — independent of F002; could ship in either order in principle. Shipping F002 first (this plan) keeps the NAS-observability-first ordering of the roadmap.
