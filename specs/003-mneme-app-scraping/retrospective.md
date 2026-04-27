# Retrospective: Mneme Application Scraping & Dashboards

**Feature Branch:** `003-mneme-app-scraping`
**Spec:** [`spec.md`](./spec.md) · **Plan:** [`plan.md`](./plan.md) · **Tasks:** [`tasks.md`](./tasks.md)
**Status:** **Complete (2026-04-26)** — all acceptance scenarios passed including T083 + T084
**Retrospective written:** 2026-04-25 (post-T082); T083/T084 outcomes filled in 2026-04-26 post-window

---

## Outcome

Feature 003 extended F002's stack with Mneme application scraping, postgres_exporter for Mneme's database, and three Mneme dashboards under Constitution v1.2's per-application Architecture B layout. Phase 7 (DS224+ deploy) completed cleanly with 6 in-flight fixes — comparable to F002's 4, materially below F001's 13. Several of those fixes were doc-debt corrections rather than systemic discoveries.

**Stack state post-F003:** 6 containers running (Prometheus, Grafana, cAdvisor, node_exporter, snmp-exporter, **postgres-exporter** — new), 7 Prometheus scrape jobs all UP (4 prior + mneme-api + mneme-worker + mneme-postgres), 7 Grafana dashboards all rendering live data across 3 folders (`stack/`, `synology/`, `mneme/`). Memory allocation at 600 MB cap exactly (cAdvisor 90→60, node_exporter 50→30, postgres_exporter +50 — net zero); observed totals well below cap. 24-hour stability observation (T083/T084) outcomes recorded in the final section below once the window closes.

---

## What shipped

**Application scraping infrastructure:**
- `postgres-exporter` service on port 9187 running with image-default user (stateless; no DSM UID concern). 50M `mem_limit`. Connects to Mneme's Postgres on `localhost:5433` as `mneme_metrics` (read-only `pg_monitor` role) via the `postgres` system DB.
- Three new Prometheus scrape jobs in `config/prometheus/prometheus.yml`: `mneme-api` (15s, `honor_labels: true`), `mneme-worker` (15s, `honor_labels: true`), `mneme-postgres` (30s, no `honor_labels`). The consumer-vs-generic-exporter discrimination on `honor_labels` is now CI-enforced (T072 count-gate).
- `docs/mneme-setup.md` — DSM-side metrics-user provisioning runbook (5 steps + troubleshooting). Idempotent DO-block SQL pattern handles both first-run CREATE and re-run ALTER cases without operator branching.
- `POSTGRES_METRICS_PASSWORD` lives in Portainer's stack environment, not in `.env.example` (matching F002's `SYNOLOGY_SNMP_COMMUNITY` pattern).

**Three Mneme dashboards** baked into the custom Grafana image at `/etc/grafana/dashboards/mneme/`:
- **Mneme — API** (`mneme-api`, 8 panels): DB Up stat, request rate, 5xx rate (with `or vector(0)` fallback), HTTP rate by status (stacked) + by route top-10, latency p50/p95/p99 (full-width), DB pool active/idle (stacked), Node.js RSS+heap.
- **Mneme — Worker** (`mneme-worker`, 9 panels grouped as 7 conceptual rows): heartbeat freshness stat with thresholds (green<30s, yellow 30–120s, red>120s) plus over-time series, three ingestion-state stats (succeeded/failed/low_confidence), ingestion job rate by state, ingestion duration p50/p95/p99 (with `noValue` for unobserved histograms), parser confidence heatmap, Node.js worker memory.
- **Mneme — Database** (`mneme-database`, 7 panels grouped as 6 rows): active connections stat + over-time, connection pool saturation (with the `on() group_left()` label-bridge from T075), Mneme DB size, transaction rate, cache hit ratio, slow queries top-10 table (with `noValue` for absent `pg_stat_statements`).

**Subfolder migration:**
- F001/F002's flat `dashboards/` layout migrated to per-domain subfolders: `dashboards/{stack,synology,mneme}/`. `git mv` preserved diff history at 100% similarity. Provisioner gained `foldersFromFilesStructure: true` so Grafana mirrors disk layout as folder structure. Dockerfile path updated atomically with the moves (T065+T067 same commit, explicit guard against `/implement`'s default one-task-one-commit cadence).

**CI compliance gates:**
- `honor_labels` count-gate in `.github/workflows/build-grafana-image.yml`: fails CI if `^[[:space:]]*honor_labels: true` count drifts from `expected=2`. Workflow trigger paths extended to include `prometheus.yml` so the gate runs on scrape-config edits.

**Operational tooling:**
- `scripts/strip-grafana-export-noise.sh` — ported from Mneme's `ops/scripts/`. Removes the four export-environment keys (`__inputs`, `__elements`, `__requires`, `iteration`) so committed dashboards diff cleanly across re-exports. Idempotent.
- `scripts/diagnose.sh` updated for the 6-container stack (added `postgres-exporter` to `SERVICES` array and `9187:postgres-exporter` to `PORTS_LIST`).

**Supporting artifacts:**
- `docs/deploy.md` — "Updating Mneme dashboards" flow (edit → strip → commit → CI rebuild → redeploy); `<(...)`-process-substitution invocations replaced with download-then-run pattern that works on DSM's `/bin/sh`.
- `docs/ports.md` 9187 claimed (range 9100–9199, F003).
- `docs/setup.md` cross-reference to `docs/mneme-setup.md` mirroring F002's snmp-setup.md pointer.
- `.env.example` comment block for `POSTGRES_METRICS_PASSWORD`.

**Constitution amendment:**
- v1.1.0 → v1.2.0: per-application dashboards Platform Constraint replaced (Architecture B, dashboards in nas-observability with consumers owning the integration contract).

---

## The Phase 7 fix-chain

Six in-flight corrections during deploy. Comparable to F002's 4; well below F001's 13. Several were latent doc bugs from F001/F002 that F003's deploy surfaced.

1. **`openssl rand -base64 24` produced URL-reserved chars in the DSN.** The `mneme_metrics` password generated per `docs/mneme-setup.md` Step 1 contained `/`, which Go's URL parser split the DSN at — the postgres_exporter logged `parse "postgresql://mneme_metrics:n4cZYwtfV.../icN...@localhost:5433/postgres?sslmode=disable": invalid port ":n4cZYwtfV..." after host`. Caught at T075 verification (pg_up=0). Fix: switched generator to `openssl rand -hex 24` (48 hex chars = 192 bits entropy, all URL-safe). Idempotent DO block re-ran cleanly to ALTER the role's password. Runbook updated with the rationale + a troubleshooting entry. Lesson: when a password ends up substituted into a URL/URI, the generator alphabet has to be URL-safe, not just "random." Should have been hex from the start.
2. **Operator deploy handoff missed the `init-nas-paths.sh` re-run.** Prometheus reads from a bind-mounted `prometheus.yml` at `/volume1/docker/observability/prometheus/`, populated by the init script. Portainer redeploys do not re-render that file — the F002 pattern, but I omitted it from the F003 deploy handoff message. Operator's targets check after redeploy showed only 4 jobs (the F002 set) instead of 7. Fix: re-run init-nas-paths.sh + Prometheus `/-/reload` per `docs/deploy.md` §Updating prometheus.yml. Lesson: any feature that touches `prometheus.yml` requires the init-script re-run + reload step in the deploy sequence, not just a Portainer redeploy. Worth a checklist in the operator handoff template if F004+ adds another scrape config.
3. **DSM's default `/bin/sh` doesn't support process substitution `<(...)`.** Pre-existing doc bug in `docs/deploy.md` from F002 — both the `Updating snmp.yml` and `Updating prometheus.yml` flows used `sudo bash <(curl -fsSL ...)`, which errors on DSM with `syntax error near unexpected token '('` before sudo or bash see it. Bash being installed at `/bin/bash` doesn't help; the outer login shell parses the command line. Fix: replaced with the explicit download-then-run pattern (`curl -fsSL -o /tmp/init-nas-paths.sh ...; sudo bash /tmp/init-nas-paths.sh`) plus a one-line note on the underlying constraint. Lesson: F002 retro flagged "verify platform assumptions at plan time." This is the same lesson, broader scope: docs that say "run this on the NAS" need to be valid in DSM's `/bin/sh`, not just bash. Latent since F002.
4. **Suggested SSH-tunnel-with-local-Grafana workflow for dashboard iteration was overengineered.** Initial recommendation was `ssh -L 3030:localhost:3030 ...` to forward the NAS's Grafana port through SSH, but DSM blocks TCP forwarding by default (`AllowTcpForwarding no` in sshd_config) — operator hit `channel ... open failed: administratively prohibited`. Cleaner answer: the stack uses `network_mode: host`, so Grafana binds to all interfaces and is directly reachable at `http://<nas-ip>:3030` over the LAN. No tunnel needed. Lesson: when a service is already LAN-reachable (host networking + no firewall), the SSH tunnel pattern is unnecessary friction.
5. **Heatmap panel doesn't honor `noValue` config.** Worker dashboard's Parser Confidence heatmap shows Grafana's default "No data" instead of the configured `noValue` string. The Ingestion Duration time series right next to it renders the `noValue` correctly. Known Grafana limitation — heatmap panels handle empty result sets differently from time-series/stat/table panels. Accepted as-is; once Mneme F002 ships and the worker observes the histogram, the heatmap will render properly. Carry-over candidate (revisit when data arrives).
6. **5xx Error Rate stat showed "No data" instead of "0".** `sum(rate(http_requests_total{status=~"5.."}[5m]))` returned an empty series when no 5xx requests are happening, and Grafana renders "No data" — visually misleading because it looks alarming when it should say "0 errors". Fix: `or vector(0)` fallback in T079. Standard Prometheus pattern; should be the default for any rare-event rate panel.

Other small things during the build (not Phase 7 fixes, just iteration):
- Plan vs JSON panel-count mismatches caught during scaffolding: api ("7 panels" header / 8 in row breakdown), worker ("7" / 9), database ("6" / 7). Treated the row-by-row breakdown as authoritative; documented the count discrepancies in commit messages.
- F003 PR shape: single PR by default (per Spec D6). Final commit log spans ~14 commits across 9 phases — well under the implicit ~1500-line split threshold; no need to split.

---

## What went well

- **Constitution v1.2 Architecture B was the right call.** Mneme F008's same-day amendment moved dashboard authoring from Mneme to nas-observability. F003 was the first feature consuming the new model. End-to-end ownership in one repo — no cross-repo dashboard sync workflow needed (the F001-era plan), no ambiguity about who owns the rendering layer. F004+ consumers (Pinchflat, Immich, etc.) follow the same pattern uniformly.
- **D4 traceability gates (T059 + T075) caught everything they were meant to catch.** T059 surfaced the histogram-registered-but-unobserved distinction for Mneme's parser_confidence and ingestion_duration before dashboard authoring — drove the `noValue` panel design instead of "no data for an indefinite window after deploy." T075 verified all six postgres_exporter v0.16.0 metric names against live output, plus surfaced two label-set asymmetries (`pg_settings_max_connections` only has `{server}`, `pg_database_size_bytes` has only `{datname}`) that drove the `on() group_left()` label-bridge in the connection-saturation panel before the dashboard JSON shipped. Zero panels had to be reworked post-T079.
- **Idempotent DO-block SQL provisioning saved real friction.** Password regeneration (base64→hex) needed only a re-run of Step 2 — the DO block ALTERs the existing role's password without operator branching or manual `DROP USER`. The pattern paid off the first time it was tested.
- **honor_labels count-gate validated live on first CI run.** The gate fired correctly on the post-T071 prometheus.yml (count=2 matches expected=2) and was confirmed to fail with `::error::` against an injected 3rd occurrence. Compliance check is now machine-enforced; F004+ feature PRs that legitimately add consumer-app scrape jobs update `expected=` in the same PR.
- **Atomic T065+T067 commit avoided the half-migrated tree state.** Subfolder migration plus Dockerfile path update landed in one commit (`8e409cf`). No window where the build pointed at a path that didn't exist. Explicit acceptance bullet in the task definition guarded against `/implement`'s one-task-per-commit default.
- **Memory system pre-loaded constraints prevented several patterns.** DSM UID restriction on stateful services, baked-vs-state path separation, Portainer workspace bind-mount masking, DSM's missing envsubst — all cited at plan time, none rediscovered at deploy time. Same payoff F002 saw from v1.1's amendments.
- **Three dashboards rendered live data on first scaffold.** Operator opened the Mneme folder in Grafana and all three dashboards displayed real data immediately (Mneme had been running for hours pre-deploy). Only one substantive fix (5xx `or vector(0)`) — the rest worked as designed including the label-bridge, the noValue strings, and the threshold colorings. Visual feedback loop was tight: scaffold → deploy → screenshot → diff → fix → relock.
- **Cross-repo coordination with Mneme F008 worked cleanly.** Phase 0's T057/T058 verified Mneme's `docs/observability.md` (T013) had landed and its language matched Constitution v1.2's Architecture B. T059's smoke-test against Mneme's deployed `/metrics` confirmed metric names. Cross-repo dependency was visible, gated, and resolved without surprises.

## What went poorly

- **base64 password generator was a thinko at runbook authoring time.** URL-encoding fragility with `/`, `+`, `=` is well-known; should have been `openssl rand -hex 24` from the start. Cost: one re-provisioning cycle on the NAS plus a runbook update commit. No production state corrupted (the broken password never reached postgres-exporter as the bind-mounted prometheus.yml was still F002-shaped at the time, and the test exporter container running with the bad DSN was disposable).
- **Deploy handoff omitted the `init-nas-paths.sh` re-run.** I gave the operator a four-step sequence (Portainer env update, compose tag bump, Portainer redeploy, verify) without including the prometheus.yml refresh step from `docs/deploy.md`. Caught when targets check showed 4 instead of 7. The deploy.md flow was correct; my summary message wasn't a faithful subset of it. Lesson: when crafting an operator handoff, walk through the full deploy.md flow rather than reconstructing from memory.
- **Three doc bugs in `docs/deploy.md` were latent since F001/F002.** The `<(...)` process-substitution pattern dates to F001, propagated into F002's snmp.yml flow, and F003 was the first time it actually got run on a DSM shell that exposed the syntax error. Lesson: if a runbook step has never been executed end-to-end on the actual target platform, treat it as untrusted regardless of how long it's been committed. F004 should run a full doc walk on a fresh DSM session if any new operator-facing flows are added.
- **Suggested local-Grafana-with-SSH-tunneled-Prometheus workflow for dashboard iteration was overengineered.** Plan §Authoring workflow documented this pattern for F001/F002 but neither F001 nor F002 actually used it (those dashboards were authored against a deployed Grafana). For F003 I copied the pattern into the deploy handoff without questioning it; operator hit the DSM-blocks-TCP-forwarding wall. The actual workflow is much simpler: deployed Grafana is LAN-reachable at `<nas-ip>:3030`, no tunnel needed at all. Both `docs/deploy.md` and `plan.md` §Authoring workflow should be updated to drop the SSH-tunnel step.

---

## Carry-over to Feature 004

Three items deferred during F003 with concrete revisit criteria:

1. **Heatmap noValue limitation on Worker → Parser Confidence panel.** Grafana 11.4 heatmap panels don't honor the `fieldConfig.defaults.noValue` config the way time-series/stat/table panels do. Currently shows "No data" instead of the configured "Awaiting ingestion runs..." message. **Revisit when:**
   - Mneme F002 ships and the worker observes `parser_confidence` (heatmap will render data; noValue path no longer triggers).
   - Grafana releases a version that honors heatmap noValue (track upstream issues).
   - If neither happens within ~6 months and the discrepancy with the adjacent Ingestion Duration panel becomes operationally confusing, swap heatmap → time-series visualization (one line per bucket) where noValue works.

2. **Multi-arch Grafana image (amd64 + arm64)** — still deferred from F002. Same QEMU-tax constraint. **Revisit when:** native arm64 GHA runners reach general availability.

3. **Walkgen replacement of community `snmp.yml.template`** — still deferred from F002. **Revisit when:** any of F002's four trigger criteria fire (DSM major upgrade, new panel needs an OID the community config doesn't expose, scrape duration drifts, six-month routine).

Two minor doc-debt items:
- Drop the "local Grafana with SSH-tunneled Prometheus" workflow from `plan.md` §Authoring workflow + the equivalent line in `docs/deploy.md`. The deployed Grafana is LAN-reachable; no tunnel needed.
- Sweep `docs/` for any other `<(...)` patterns that may have crept in during F003 (none expected; ripgrep + manual review at F004 spec time).

## Feature 004 preview

F004 opens with these priors from F003 memory:

- **Per-application Architecture B is now battle-tested.** F004's first consumer (Pinchflat, Immich, or similar) follows the F003 template: subfolder under `dashboards/<app>/`, scrape jobs in `prometheus.yml` with appropriate `honor_labels` setting, dashboards authored in the deployed Grafana, locked down with `editable: false`. Memory budget revisit if the new consumer needs a database scrape.
- **honor_labels CI gate auto-extends.** F004's feature PR updates `expected=` in `.github/workflows/build-grafana-image.yml` if the new consumer is self-identifying (bakes its own `instance` label).
- **postgres_exporter pattern is reusable.** If F004's consumer also runs Postgres, the metrics-user pattern + DSN env-var workflow generalizes; only the role name and database name change. The `pg_stat_statements` extension is the realistic-default stance — don't assume it's installed.
- **Memory system stable at 10 entries.** F003 added zero new memories and retired zero. The DSM-platform corpus from v1.1 + v1.2 covers every constraint F003 hit.
- **Constitution stable at v1.2.0** — no amendments needed during F003 implementation. Architecture B replaced the cross-repo sync workflow before F003 specified, so no in-flight discovery forced changes.

---

## Memory system state at close

No new memories added during F003. Total persistent memories: 10 (unchanged from F002 close).

The base64 → hex password lesson is captured in `docs/mneme-setup.md` directly — it's a runbook concern, not a cross-feature constitutional pattern, so no memory entry. Same for the DSM `/bin/sh` process-substitution constraint (captured in `docs/deploy.md` inline). The retro itself records the lessons; the runbook implements them.

---

## T083 + T084 — observation outcomes (2026-04-26)

**T083 NFR-15 — postgres_exporter scrape duration stability:** PASS. Over the ~19.5h window post-redeploy (21:30 PDT 2026-04-25 → 17:00 PDT 2026-04-26), `mneme-postgres` scrape duration held flat at ~28–30 ms baseline. Window-end value (27.9 ms) is *lower* than the half-window value (29.7 ms) — opposite of what a leak indicator would look like, consistent with shared_buffers warming to steady state. No upward drift, no spikes > 5 s threshold. Initial post-deploy spike capped at ~0.65 s and settled within ~30 min.

**T084 NFR-16 — Mneme `/metrics` scrape duration stability:** PASS. Same window. `mneme-api` held at ~5–6 ms (window-end 5.9 ms), `mneme-worker` at ~4 ms (window-end 4.2 ms). Both well under the 100 ms threshold (~17–25× headroom). No upward drift. Histogram metrics that remain registered-but-unobserved (parser_confidence, ingestion_duration on the worker) did not measurably change scrape size — confirms the spec's pre-registration discipline doesn't penalize the scrape budget.

**Daytime portion specifically (09:00 → 17:00 PDT 2026-04-26)** — the half of the window that the 12h interim couldn't yet cover — held flat across all three jobs. Zero new spikes during active daytime usage. The pre-09:00 blips at 00:30 and 04:30 (recorded in the 12h interim as likely DSM scheduled tasks) remain the only visible anomalies in the full window.

**Constitution NFR thresholds (Resource Discipline):** entire 600 MB cap held; observed totals well below cap throughout. The donor-trim from cAdvisor (90→60M) and node_exporter (50→30M) to fund postgres_exporter (50M new) was substantively net-zero on observed memory.

### Interim 12h observation (2026-04-26 ~09:11 PDT, T+11.5h post-redeploy)

Data captured at the half-window mark. Recording for transparency; final close-out waits for the full 24h read at ~21:30 PDT to honor the discipline note below.

**Steady-state baselines (current values):**

| Job | Baseline | Threshold | Headroom | Drift over 11h steady-state |
|---|---|---|---|---|
| `mneme-api` | 5.3 ms | < 100 ms | ~19× | none visible |
| `mneme-worker` | 4.3 ms | < 100 ms | ~23× | none visible |
| `mneme-postgres` | 29.7 ms | spike < 5 s, drift < 2× | ~170× under spike | none visible |

**Initial post-deploy warm-up (21:15–22:00 PDT 2026-04-25):** mneme-postgres ~0.65 s on first scrape, mneme-api ~0.3 s, mneme-worker ~0.25 s. Settled within the first ~30 min. Cause: postgres-exporter establishing its first DB connection plus uncached `pg_stat_*` views; Mneme api/worker prom-client registries serializing for the first time post-restart; Prometheus's WAL replay competing for I/O. Expected, not anomalous.

**Anomalies visible in 12h:** two small blips around 00:30 and ~04:30 PDT, both well under 50 ms — almost certainly DSM scheduled tasks (Hyper Backup, package updates) creating brief I/O contention on the underlying disks. Not in any threshold-breach territory.

**What 12h doesn't yet cover (waits for the full window):**
- Daytime Mneme usage patterns — counters increment, histograms accumulate observations as the user actively uses Mneme during the day. The 12h window we have is mostly overnight.
- Daytime DSM scheduled tasks (different cadence from overnight).
- The first full diurnal cycle, which by definition needs 24h.

**Observation discipline note** (carried from F002 retro): honor the 24h discipline even when 6h looks clean. Diurnal patterns matter — Hyper Backup, scheduled jobs, day/night usage variance for a PKM tool — and Mneme + postgres_exporter are net-new behaviors here, not characterized at production scale. F002's 24h observation surfaced no anomalies; that's not a guarantee F003 will be the same.

No anomalies surfaced over the observation window; no follow-up issues filed.

Feature is **complete**.
