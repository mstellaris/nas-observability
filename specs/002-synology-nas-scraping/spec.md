# Feature Specification: Synology NAS Scraping & Dashboards

**Feature Branch:** `002-synology-nas-scraping`
**Status:** Draft
**Created:** 2026-04-24
**Depends on:** Feature 001 complete (2026-04-24); Constitution v1.1.0 (amended 2026-04-24)

---

## Overview

Feature 002 turns "generic observability of the Docker host" (what F001 shipped) into "observability of *this* Synology." It adds an SNMP exporter that queries the NAS's own SNMP agent for Synology-specific metrics — CPU, RAM per-volume disk usage, disk SMART health, per-disk and system temperature, per-interface network throughput — and ships three baked dashboards that consume those metrics: **NAS Overview**, **Storage & Volumes**, and **Network & Temperature**.

Alongside the core scraping work, F002 picks up three operational improvements carried over from F001's retrospective. The most load-bearing of these is `scripts/diagnose.sh`: a one-command diagnostic dump that would have compressed F001's 11-round deploy cycle substantially. Building it early in F002 pays compounding dividends on this feature's Phase 8 and every feature afterward. The GitHub Actions Node.js 24 migration lands here too — the deadline is 2026-09-16, and carrying it into F002 gets it done with five months of runway.

After F002, the stack shows NAS-level health and its own health in the same place. What it still doesn't do: scrape application `/metrics` endpoints (Feature 003+), send alerts (dedicated alerting feature), monitor the UPS via NUT (its own future feature), or expose Grafana externally (separate external-access feature). Those remain out of scope per the roadmap.

---

## User Scenarios & Testing

### Primary User Story

As Stellar, I want to see my NAS's health — CPU, RAM, per-volume disk usage, disk health, temperature, and network throughput — in Grafana alongside the stack's self-monitoring, so that when something feels slow or the NAS is running hot, I can differentiate "NAS hardware under pressure" from "observability stack under pressure" and act on the right signal.

### Acceptance Scenarios

**Scenario 1: SNMP enablement on the NAS follows the documented runbook**

**Given** a DS224+ where SNMP has never been enabled
**When** the operator follows `docs/snmp-setup.md` (Control Panel → Terminal & SNMP → SNMP tab, plus any firewall allow-rule for the SNMP exporter's scrape source)
**Then** SNMPv2c is enabled with the documented community string
**And** an `snmpwalk` from the NAS itself (or any LAN host) returns entries from the Synology OID tree (`.1.3.6.1.4.1.6574`)
**And** no DSM UI click-trail is required beyond what the runbook describes

**Scenario 2: First F002 deploy succeeds alongside the F001 stack**

**Given** F001's stack is running and SNMP is enabled per Scenario 1
**When** the operator updates the compose file (SNMP exporter added) and redeploys via Portainer
**Then** a fifth container (`snmp-exporter`) enters the `running` state
**And** all existing F001 containers remain `Up` with no restarts caused by the change
**And** the SNMP exporter process runs as UID 1026 (matches `docker inspect snmp-exporter --format '{{.Config.User}}'`)

**Scenario 3: SNMP scrape target reports UP**

**Given** the expanded stack is running
**When** the operator visits `http://<nas-ip>:9090/targets`
**Then** a `synology` scrape job appears alongside the existing three
**And** its single target (`localhost:9116`, scraping the NAS's SNMP tree) reports state `UP`
**And** the job's scrape duration is below its configured timeout (60s interval, 30s timeout per Decision D3)

**Scenario 4: NAS Overview dashboard renders with real data**

**Given** SNMP scraping has been running for at least two scrape cycles
**When** the operator opens the **NAS Overview** dashboard in Grafana
**Then** CPU, RAM, aggregate disk usage, and system temperature stat panels show non-zero current values sourced from SNMP
**And** CPU-over-time, RAM-over-time, and load-average time series populate
**And** the dashboard renders within 3 seconds of opening (NFR-8)

**Scenario 5: Storage & Volumes dashboard shows per-volume detail**

**Given** the NAS has at least one configured volume
**When** the operator opens **Storage & Volumes**
**Then** per-volume usage (bar or gauge), per-volume free space, SMART health per disk (up/down), and volume IOPS-over-time panels are populated
**And** the dashboard correctly distinguishes between disks (the two SATA drives) and volumes (the SHR volume atop them)

**Scenario 6: Network & Temperature dashboard shows interface and thermal telemetry**

**Given** the NAS has at least one active network interface
**When** the operator opens **Network & Temperature**
**Then** per-interface throughput (in/out) time series is populated for each configured NIC
**And** per-disk temperature stat panels show current values
**And** system temperature and fan speed (if exposed) time series populate

**Scenario 7: Memory budget respected**

**Given** the expanded stack has been running for at least 30 minutes
**When** the operator runs `docker stats --no-stream`
**Then** the SNMP exporter is within its declared `mem_limit` (40M per Decision D5)
**And** the sum of `mem_limit` across all five services is exactly 600M (constitutional cap; see Decision D5 for budget math)
**And** observed total stack memory is well below the cap (based on F001 observed at ~224 MiB with SNMP exporter expected ~20–40 MiB)

**Scenario 8: SNMP scraping doesn't overload the NAS**

**Given** SNMP scraping has been running continuously for at least 24 hours
**When** the operator checks the Stack Health dashboard's Scrape Duration panel
**Then** the `synology` job's scrape duration is stable (not climbing over time — would indicate resource leak in snmp_exporter or the NAS SNMP daemon)
**And** the NAS's own CPU usage (visible in the NAS Overview dashboard) shows no sustained elevation correlated with scrape cycles

**Scenario 9: `scripts/diagnose.sh` provides actionable operator info**

**Given** the stack is running (fully or partially)
**When** the operator runs `sudo bash scripts/diagnose.sh` on the NAS
**Then** output includes: per-container state and uptime; last 20 lines of each service's logs; `docker stats --no-stream` filtered to nas-observability services; host ownership and mode of each bind mount under `/volume1/docker/observability/`; port-in-use check for each port declared in `docs/ports.md`
**And** total output is readable within a single terminal screen for healthy cases, and clearly highlights the first failure for broken cases
**And** the script works whether zero, some, or all of the expected containers are running (e.g., during a partial deploy)

**Scenario 10: CI workflow continues to publish after Node.js 24 migration**

**Given** the GitHub Actions workflow has been updated to Node.js 24-capable action versions
**When** a PR bumps the Grafana image (any change under `docker/grafana/**`) and lands on `main`
**Then** the workflow runs to completion successfully
**And** GHCR receives new `v<semver>` and `sha-<short>` tags
**And** the deprecation warning from F001's first CI run is gone

### Edge Cases

- **SNMP not enabled on the NAS.** Scrape returns a connection refused / timeout error and the `synology` target reports DOWN in `/targets`. Dashboards show "no data" panels. This is the expected state when the Scenario 1 runbook has not yet been completed — documented in `docs/snmp-setup.md` as the first-deploy sequence: enable SNMP on the NAS before redeploying the compose stack.
- **Community string mismatch.** Authentication-level error from `snmp-exporter`. Target shows DOWN with a descriptive error in the target details. Recovery: verify the community string matches between DSM's SNMP settings and `snmp.yml` (or `.env` if we parameterize it).
- **Deep SNMP walk exceeds scrape_timeout.** The first walk of Synology's full OID tree can be slow on a cold NAS; D3's 30s timeout gives generous headroom but if it ever exceeds, Prometheus records a scrape failure and retries on the next interval. No silent data loss.
- **Port 9116 collision with another service on the NAS.** Handled via `docs/ports.md` — if another service is already bound there, the compliance checklist would've flagged it at PR time. Empirical confirmation via `ss -tlnp` on the NAS (or via `scripts/diagnose.sh` port-check output) during deploy.
- **Dashboard references a metric the NAS doesn't expose.** Different Synology models expose different subsets of the MIB tree. Panels for missing metrics render as "no data" rather than erroring. The MIB source strategy (Decision D2) walks against the *specific* DS224+ so committed `snmp.yml` only queries for metrics this model actually exposes; the dashboards query only metrics in that walked set.
- **Disk hot-swap.** A replaced disk gets a new label in SNMP output, breaking continuity of per-disk panels that reference the old label. Expected; operator replaces the panel's label filter when they swap a disk. Not worth designing around at homelab scale.
- **NAS reboot.** SNMP exporter restart policy (`unless-stopped`) brings it back; scrape gap for the downtime appears as "no data" in dashboards (per F001's Scenario 8 pattern); SNMP exporter itself is stateless so there's nothing to lose.
- **`diagnose.sh` run before the stack is ever deployed.** Script detects zero nas-observability containers and reports "stack not yet deployed" rather than erroring. Useful as a pre-deploy sanity check.
- **Node.js 24 migration breaks a GHA step.** CI fails on the first run post-merge; hotfix PR pins to the previously-working action version while the incompatibility is investigated. Constitution Governance already covers this pattern (PRs that fail compliance are blocked regardless of other merit).

---

## Requirements

### Functional Requirements

- **FR-16:** The system MUST add a fifth service `snmp-exporter` to `docker-compose.yml` using the upstream `prom/snmp-exporter` image at a pinned version, with `network_mode: host`, `restart: unless-stopped`, and an explicit `mem_limit`. [Constitution: Principles I, III, IV]
- **FR-17:** The `snmp-exporter` service MUST run as `user: "1026:100"` (the DSM admin UID:GID, per constitution v1.1 §Platform Constraints "DSM UID restriction on `/volume1/`"). If it bind-mounts any writable path under `/volume1/`, the path's chown MUST match. [Constitution v1.1: Platform Constraints §DSM UID restriction]
- **FR-18:** The system MUST commit `config/snmp_exporter/snmp.yml` to the repo, populated per Decision D2 (walkgen output from this specific DS224+ as the primary source). The NAS-side placement of this config file MUST follow F001's pattern: absolute host path populated by the init script via `curl`, never relative-to-compose. [Constitution: Principle II]
- **FR-19:** The system MUST add a `synology` scrape job to `config/prometheus/prometheus.yml` targeting `localhost:9116` with `scrape_interval: 60s` and `scrape_timeout: 30s` (per Decision D3). Existing F001 scrape jobs MUST be unchanged. [Constitution: Principles III, IV]
- **FR-20:** The system MUST bake three NAS dashboards into the custom Grafana image at `/etc/grafana/dashboards/` (same flat location as F001's `stack-health.json`, not in a subfolder). Dashboards are NAS Overview, Storage & Volumes, and Network & Temperature. Each dashboard MUST declare tags including `synology` plus a descriptive second tag (e.g., `nas-overview`, `storage`, `network`) for browser-based filtering in Grafana. Rationale: Grafana's dashboard browser surfaces folders, tags, and search; tags-based organization scales better than per-feature subfolders and avoids reconfiguring the file-based provisioner (which watches a single directory non-recursively by default). [Constitution v1.1: Platform Constraints §Separate baked config from persisted state]
- **FR-21:** Each NAS dashboard MUST reference the Prometheus datasource by explicit UID (`datasource.uid: "prometheus"` matching the provisioned datasource from F001). [Constitution v1.1: Platform Constraints §Grafana datasource UIDs must be explicit]
- **FR-22:** Dashboards MUST be authored from scratch (not forked from community dashboards) per Decision D4. Each panel's PromQL query MUST be traceable to a metric that this specific DS224+ exposes, as verified by the walkgen output.
- **FR-23:** The system MUST commit `docs/snmp-setup.md` as the DSM-side runbook for enabling SNMP. The runbook MUST cover: DSM's SNMP settings UI location (Control Panel → Terminal & SNMP → SNMP tab), SNMPv2c configuration with community string selection, any DSM firewall rule required for the SNMP exporter's localhost scrape, and a verification step (`snmpwalk` from the NAS itself returning Synology OIDs). [Constitution: Principle II §carved-out manual-step exception]
- **FR-24:** The system MUST update `scripts/init-nas-paths.sh` to create `/volume1/docker/observability/snmp_exporter/` and populate `snmp.yml` there, chowned to `1026:100` with mode 644 — mirroring the Prometheus config placement pattern. [Constitution: Principle II; v1.1: Platform Constraints §DSM UID restriction]
- **FR-25:** The system MUST update `docs/ports.md` with the `9116` assignment for `snmp-exporter` in the 9100–9199 range. This fulfills the reservation already noted in F001's ports table. [Constitution: Principle III]
- **FR-26:** The system MUST commit `scripts/diagnose.sh`, a one-command diagnostic dump with the output contract described in Scenario 9. The script MUST be committed with mode 100755 (executable bit). It MUST handle partial-stack states (zero, some, or all expected containers running) without erroring out. [Operational improvement carried from F001 retrospective]
- **FR-27:** The system MUST update `.github/workflows/build-grafana-image.yml` to pin action versions that support Node.js 24: `actions/checkout`, `docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`. Exact version pins are resolved in `plan.md`. The workflow MUST continue to publish both `v<semver>` and `sha-<short>` tags with no other behavioral change. [Operational improvement carried from F001 retrospective]
- **FR-28:** Every PR that adds or modifies a service in this feature MUST satisfy the constitutional compliance checklist (pinned version, explicit `mem_limit`, total ≤ 600M, port declared in `docs/ports.md`, bind mount documented) per F001's established pattern. [Constitution: Governance]

### Non-Functional Requirements

- **NFR-7:** Total Feature-002 memory allocation MUST keep the stack within the 600M constitutional cap. F002 adds 40M for `snmp-exporter`, bringing the allocated total to exactly 600M (see Decision D5 for budget math and observed headroom). [Constitution: Principle IV]
- **NFR-8:** Each NAS dashboard MUST render within 3 seconds on first view after at least two scrape cycles have populated data. (Matches F001's Grafana install load characteristics.)
- **NFR-9:** The `synology` scrape job's observed duration MUST remain under its 30s timeout under normal operation, with headroom — a healthy walk is expected to be 2–8 seconds on this DS224+.
- **NFR-10:** SNMP scraping MUST NOT induce observable CPU elevation on the NAS itself across scrape cycles. Defined as: the NAS Overview dashboard's CPU panel shows no sustained pattern correlating to the 60s scrape cadence.
- **NFR-11:** `scripts/diagnose.sh` MUST complete in under 10 seconds on a healthy stack. It's operator-facing for live debugging; anything slower loses its utility.
- **NFR-12:** CI workflow runtime post-Node.js-24-migration SHOULD remain under 5 minutes (F001's soft target). The migration is a version bump, not a workflow redesign.

### Key Entities

- **SNMP exporter** (`prom/snmp-exporter`): the upstream container that translates SNMP-queried values from the NAS into Prometheus metrics format. Stateless; reads `snmp.yml` at start. Bound to port 9116 on the NAS host.
- **`snmp.yml`**: the SNMP exporter's configuration, mapping Prometheus metric names to SNMP OIDs under the Synology enterprise tree (`.1.3.6.1.4.1.6574`). Walked against this DS224+ specifically (Decision D2).
- **Synology SNMP agent**: DSM's built-in SNMP daemon, enabled per `docs/snmp-setup.md`. Not managed by this stack.
- **NAS dashboards**: three Grafana JSON files under `docker/grafana/dashboards/` (alongside F001's `stack-health.json`, flat layout per FR-20) — NAS Overview, Storage & Volumes, Network & Temperature. Baked into the custom Grafana image at `/etc/grafana/dashboards/` per v1.1 Platform Constraints. Tags on each dashboard support browser-based organization (`synology` + a descriptive second tag).
- **`scripts/diagnose.sh`**: operator-facing one-command diagnostic. Not deployed; lives in the repo for SSH'd execution on the NAS.
- **Walkgen output**: the artifact produced by running `snmp_exporter generator` against this DS224+'s SNMP tree. Committed as `config/snmp_exporter/snmp.yml`; the walkgen procedure is documented in `docs/snmp-setup.md` for forks regenerating for their specific NAS.

---

## Specific Decisions (resolved in this spec)

These are the six decisions the user required the spec to resolve rather than defer to `plan.md`.

### D1. SNMP version — SNMPv2c

For a single-operator homelab LAN with Tailscale-gated access and no external exposure, **SNMPv2c** is the chosen version. Rationale:

- **Threat model**: anyone with access to the home LAN already has access to far more sensitive surfaces (DSM admin UI, SSH, etc.) than the MIBs we're reading. Operational telemetry (CPU, RAM, disk, temperature) is not sensitive in this context.
- **Simplicity**: community-string-based auth is a single value; v3's auth + privacy configuration has more moving parts (engine IDs, auth protocol, priv protocol, passphrases) without proportionate threat-model value here.
- **Upstream ecosystem**: most Synology+Prometheus examples use v2c, so the MIB mapping we walk against is well-trodden.

Community string lives in `.env` (gitignored) and is substituted into `snmp.yml` via env-var placeholder OR into a separate secrets file that the init script curls down. Plan.md picks the mechanism; the spec commits to "not committed in plaintext to the repo."

The mechanism decision has a subtle constraint worth naming: **SNMP exporter does not natively expand environment variables in `snmp.yml`.** Plan.md chooses between (a) an entrypoint override that pre-processes `snmp.yml` with `envsubst` at container start, substituting `${SYNOLOGY_SNMP_COMMUNITY}` before handing off to the exporter binary, or (b) a separate secrets file curl'd by the init script and referenced via a secondary include or auth block in the snmp.yml. Either option keeps the secret out of the repo; plan picks and justifies before the compose entry is written.

If we ever expose SNMP access beyond the NAS itself (e.g., scraping a second NAS from this one's network), we re-evaluate v3. For F002's single-device scope, v2c is correct.

### D2. MIB source strategy — walkgen against this DS224+, committed as primary `snmp.yml`

Between the three options (a) official Synology MIBs, (b) community-borrowed `snmp.yml`, (c) walkgen against the live NAS, the spec picks **(c) with a hybrid twist**: walk against this specific DS224+ on DSM 7.3 and commit the generator output as the repo's primary `config/snmp_exporter/snmp.yml`.

Rationale:

- **Accuracy over portability**: (c) queries exactly what this model exposes on this DSM version. No phantom metrics that aren't available (which would cause panels to perpetually show "no data"), no missing metrics that are available but the MIB file forgot about.
- **Self-contained for this deployment**: committing the walkgen output means a redeploy on this NAS doesn't require re-running the generator. Only a DSM major upgrade that changes the OID tree would trigger a re-walk.
- **Forks covered via runbook**: `docs/snmp-setup.md` documents the walkgen procedure so a fork on a different NAS model regenerates `snmp.yml` with two commands. Forks get the same accuracy benefit with a small one-time setup cost.

Rejected alternatives:
- **(a) Official MIBs**: risks including metrics not exposed on DS224+ specifically (phantom series, wasted scrape work). DSM model-specific exposure varies enough that "shipping a universal Synology MIB" is a mirage.
- **(b) Community snmp.yml**: fastest to ship but inherits design decisions we don't understand. Maintenance means reading someone else's label conventions. For a spec-kit-disciplined project, owning the config beats borrowing it.

**Fallback if walkgen fails or blocks F002:** use a well-maintained community `snmp.yml` (e.g., wozniakpawel or RedEchidnaUK) as a temporary scaffold, then replace with walkgen output in a follow-up PR once the generator environment works. The spec's preference remains walkgen; the fallback prevents F002 from being blocked by SNMP-tooling friction (`snmp_exporter generator` requires MIB files on the PATH plus a working MIB compiler, which can bite on a minimal NAS shell environment).

### D3. SNMP scrape timing — 60s interval, 30s timeout

SNMP walks are expensive: the exporter walks the configured OID subtree on every scrape. The F001 global `scrape_interval: 15s` would hammer the NAS's SNMP daemon with a scrape every 15s, each potentially taking several seconds.

Chosen timing for the `synology` scrape job:

```yaml
- job_name: synology
  scrape_interval: 60s
  scrape_timeout: 30s
  static_configs:
    - targets: ['localhost:9116']
```

Rationale:
- **60s interval**: NAS hardware metrics (temperature, disk usage, volume free space) don't change meaningfully in sub-minute windows. 60s gives real-time-enough dashboards without subsystem churn.
- **30s timeout**: a healthy SNMP walk on this DS224+ is expected to complete in 2–8 seconds. 30s is ~4x the expected headroom, covering cold-cache cases and transient NAS load without permitting runaway walks.
- **Observable via Stack Health's Scrape Duration panel**: if the `synology` job's scrape duration ever climbs toward 30s in steady state, that's a regression signal — investigate SNMP daemon resource leak or an overbroad `snmp.yml` that walks too many OIDs.

### D4. Dashboard authorship — build from scratch

Between (A) author three dashboards from scratch and (B) fork community dashboards heavily, the spec picks **(A) from scratch**.

Rationale:
- **Spec-kit discipline**: every panel's PromQL query is our own choice, traceable to a metric we know the NAS exposes (Decision D2). Maintenance doesn't require reading someone else's conventions.
- **Scope discipline**: forking community dashboards often drags in panels for MIBs we haven't walked, extensions we don't use, or metrics that don't apply to DS224+. Three from-scratch dashboards with ~6–8 panels each is a smaller, better-owned surface.
- **Dashboard authoring workflow**: author in a local Grafana with `editable: true`, iterate in the UI, export JSON, commit. This is the workflow F001 established; F002 continues it.

Community dashboards are fine as *inspiration* for panel types and useful queries; they are not the starting point for our JSON.

### D5. SNMP exporter memory allocation — 40 MB

F001's T027 observed actual stack usage at ~224 MiB against 560 MiB allocated (40% utilization). The theoretical 40 MiB reservation for F002's SNMP exporter from F001's Spec D2 remains correct: `prom/snmp-exporter` at single-device scrape scale typically consumes 15–40 MiB in practice.

Spec D5 allocation:

| Service         | `mem_limit` | Feature   | Notes                                                    |
|-----------------|-------------|-----------|----------------------------------------------------------|
| Prometheus      | 280M        | F001      | Unchanged                                                |
| Grafana         | 140M        | F001      | Unchanged                                                |
| cAdvisor        | 90M         | F001      | Unchanged (observed at 30M, massive headroom)            |
| node_exporter   | 50M         | F001      | Unchanged (observed at 7M)                               |
| **snmp-exporter** | **40M**   | **F002**  | **Consumes F001's reserved headroom; new total = 600M**  |
| **Total cap**   | **600M**    | Constitution | Principle IV                                          |

Total allocated sits exactly at the 600M constitutional cap. Observed F001 usage (~224 MiB) plus expected snmp-exporter usage (~20–40 MiB) puts real total around 250–270 MiB — comfortably 55% under the allocated ceiling, leaving substantial runway for future features to reshuffle within the cap without needing a constitutional amendment.

**If 40M proves tight in practice**: the first move is *not* amending the 600M cap. Per F001 Spec D2's precedent, trim from the service that has the most observed headroom — cAdvisor (30M observed vs. 90M limit, 67% unused) is the obvious donor. A future PR could move 20M from cAdvisor to snmp-exporter (90M→70M, 40M→60M) well within the cap.

### D6. Multi-arch Grafana image — deferred to a later feature

Between shipping `linux/amd64,linux/arm64` multi-arch builds in F002 versus deferring, the spec **defers**. Rationale:

- **Build-time cost is significant.** QEMU-based arm64 builds under GHA's amd64 runners typically take 3–5× longer than native. F001's build runs in ~40 seconds; multi-arch would push it to 2–5 minutes per push. Every merge to `main` pays that cost.
- **Usage frequency is low.** Grafana image development happens a few times per feature (to add dashboards). The workaround on Apple Silicon is `docker pull --platform linux/amd64 ...`, a one-time addition to a command already being typed.
- **Better alternative on the horizon.** Native arm64 GHA runners (in beta / limited availability as of early 2026) would let us add multi-arch without the emulation tax. Revisiting when they're generally available makes more sense than paying emulation overhead now.

Documented as a non-blocking carry-over still; revisit when arm64 runners are a clean option or when Apple Silicon dev frequency crosses a threshold.

---

## Success Criteria

This feature is complete when:

1. SNMP is enabled on the DS224+ via `docs/snmp-setup.md`; an `snmpwalk` from the NAS returns Synology OIDs.
2. A fifth container (`snmp-exporter`) is running alongside F001's four; `docker inspect` shows `User: 1026:100`.
3. `http://<nas-ip>:9090/targets` shows the `synology` scrape job with state `UP` and scrape duration < 10s.
4. All three NAS dashboards render with real data within 3 seconds of opening.
5. `docker stats --no-stream` confirms total allocated memory at 600M with observed usage comfortably below.
6. `sudo bash scripts/diagnose.sh` produces the output contract from Scenario 9 in under 10 seconds.
7. The GHA workflow runs to completion on the first post-migration push with no Node.js deprecation warnings.
8. `docs/ports.md`, `docs/setup.md` troubleshooting, and `scripts/init-nas-paths.sh` all reflect the new snmp-exporter service.
9. Stack has been running continuously for at least 24 hours with stable SNMP scrape duration (NFR-9) and no observable NAS CPU elevation pattern from scrapes (NFR-10).

Explicitly not required for this feature:

- Alertmanager or any alert rules for NAS-level conditions (dedicated alerting feature).
- Application scraping of any kind (Feature 003+).
- UPS monitoring via NUT (future feature).
- Multi-arch Grafana image (Decision D6 deferred).
- Any expansion of the 600M RAM cap or 30d retention ceiling (Constitution Principle IV).

---

## Out of Scope

- **Application scraping and application dashboards** (Mneme, future apps) → Feature 003+. F003 will add the dashboard sync CI step that pulls `ops/dashboards/` from consumer repos into the Grafana image build context, alongside the nightly GHA schedule that was intentionally deferred from F001.
- **Alertmanager, alert rules, email delivery** → dedicated alerting feature, expected after F003+ establishes enough consumer context to define actionable alerts.
- **UPS monitoring** via NUT (Network UPS Tools). NUT is a separate subsystem from SNMP and typically ships as its own exporter + dashboard set. Deferred to a future dedicated feature to keep F002's scope tight.
- **External access to Grafana** (Caddy reverse proxy + basic auth or similar). Separate feature; out of scope here.
- **Multi-arch Grafana image** (per Decision D6). Revisit when arm64 GHA runners are generally available.
- **Expanding the 600M RAM cap or 30d retention** (Constitution Principle IV). Work within the existing envelope. If a future feature genuinely needs more, amend the constitution deliberately.
- **Migrating to SNMPv3** (per Decision D1). Revisit if the threat model changes (e.g., scraping a remote NAS across a less-trusted network).
- **postgres_exporter** — ships with the first Postgres-backed app's feature (Mneme in F003, most likely).

---

## Notes for `/plan` and `/tasks`

When this feature is started, `plan.md` resolves the following (explicitly deferred from this spec):

- **Exact SNMP exporter image version.** Verify the tag exists on Docker Hub (`docker manifest inspect prom/snmp-exporter:<tag>`) at plan time — F001 discovered that upstream tag assumptions occasionally lie (`grafana/grafana:11.4.0-oss` didn't exist; correct was `grafana/grafana-oss:11.4.0`). Check before pinning.
- **Exact `snmp.yml` contents.** The walkgen output from this DS224+ is mechanical — the plan specifies the procedure (`snmp_exporter generator` against the DS224+ with the Synology MIB tree) and the post-walk review criteria (prune noisy OIDs that don't inform any dashboard panel).
- **Community string handling.** The spec commits to "not in plaintext in the repo." Plan chooses between: (a) a dedicated `.env` key (`SYNOLOGY_SNMP_COMMUNITY`) substituted into `snmp.yml` at container start via an entrypoint override, or (b) a separate secret file curl'd by the init script. Option (a) is more declarative; option (b) keeps the secret out of compose's environment surface. Plan picks.
- **Exact Grafana dashboard panels for each of the three dashboards.** Spec commits to the three dashboards and their categorical coverage; plan designs individual panels, chooses specific OIDs to visualize, and writes the PromQL. Panel count target: 6–8 per dashboard (matches Stack Health's density from F001).
- **Exact `scripts/diagnose.sh` output format.** Spec commits to what the script covers (container states, logs, stats, bind-mount ownership, port-in-use). Plan designs the structure: order of sections, how failures are highlighted, whether output is plain text or structured (JSON option for machine readability later).
- **Exact GHA action version pins.** Spec commits to Node.js 24 migration; plan specifies the version pin for each of the four actions (`actions/checkout@v5` or whatever the current Node.js 24-capable minor version is, etc.) and documents the source where each version's Node.js support was verified.
- **SNMP exporter bind mount layout.** Config at `/volume1/docker/observability/snmp_exporter/snmp.yml` (mirroring Prometheus's pattern) vs. a structure that leaves room for future SNMP-exporter-related artifacts. Plan decides.
- **`docs/snmp-setup.md` contents.** Spec lists what it covers (DSM SNMP enablement, community string choice, firewall, walkgen procedure for forks, verification). Plan drafts the actual instructions with screenshots-or-steps per DSM UI element.

`tasks.md` will decompose into obvious phases: (1) operational improvements first (`diagnose.sh`, GHA migration) so they're available for the rest of F002's work, (2) SNMP enablement runbook and walkgen, (3) `snmp.yml` commit, (4) compose updates + init script updates + prometheus.yml scrape job, (5) three dashboards baked into the image, (6) DS224+ deploy and acceptance walk-through. Phase 1 lands first deliberately — `diagnose.sh` becomes the debugging tool for F002's own Phase 8 if anything goes sideways.
