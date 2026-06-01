# Implementation Plan: Mneme Log Dashboards (Frontend RUM + Backend Logs)

**Feature Branch:** `005-mneme-log-dashboards`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-05-31

---

## Technical Context

F005 is the first feature implemented after F004 brought logs/RUM live. F004 made Mneme's frontend (Faro → Loki) and backend (pino + postgres → Loki) telemetry *explorable* in Grafana; F005 turns the ad-hoc Explore queries into **two curated, baked dashboards** under the existing `mneme/` folder — the follow-up F004 explicitly deferred. It is the first feature to add **Loki-backed** dashboards; all seven existing dashboards are Prometheus-backed.

The component count is zero: **no compose service, no datasource, no port, no backend, no Loki/Alloy config change.** The only deployed artifact is the custom Grafana image rebuilt with two added dashboard JSONs (`VERSION` 0.3.0 → 0.4.0). FR-68 fences this hard.

The substantive work is entirely in **one contract surface: LogQL query correctness against live data.** Three things make that non-trivial, and each is a place a hand-authored query gets silently wrong:
1. **The console-echo dedup (Spec D2)** — Faro emits a *second* `kind=exception` stream per error; the only deterministic separator is the `console.error:` value-prefix, not `kind` and not `detected_level`. Get this wrong and every error count doubles.
2. **Mixed-format backend parsing (Spec D7)** — api/worker are pino JSON, postgres is plain text; `| json` parses the former and silently empties the latter.
3. **Web-vitals as Loki measurements, not Prometheus histograms** — aggregated query-time via `| unwrap`, with a live field-name ambiguity (`cls` vs `value_cls`) and per-metric CWV thresholds.

This plan resolves all three to concrete (draft) LogQL and panel configs, and front-loads a **Phase 0 "freeze against live Loki"** gate — the F004-Phase-0 analog. The F001 lesson (don't assume; confirm live) applies directly: label keys, the echo prefix, the canonical web-vitals field, the pino level encoding (numeric vs string), and the postgres severity pattern are all **verified against the running Loki before any panel query is frozen.**

**Runtime & images:**
- Custom Grafana image rebuilds `v0.3.0 → v0.4.0` with two added baked dashboards. No base-image change (still `grafana/grafana-oss` at the pinned `GRAFANA_VERSION`).
- Loki (`grafana/loki:3.3.2`), Alloy (`grafana/alloy:v1.5.1`), and all F001–F003 images/versions **unchanged**.
- The `uid: loki` datasource (baked in F004) is consumed **unchanged** — no datasource work.

**Cross-repo relationship:** none that blocks. The producers (Mneme F012 frontend, F008 backend) already ship live into Loki via F004's pipeline. F005 consumes that live data and requires no Mneme change. (If anything, F005's `faro-verification.md`-frozen queries are a useful reference back to Mneme, but that's informational, not a dependency.)

**Networking / user / bind mounts:** unchanged. No new ports (the `3100–3199` band is untouched). Dashboards bake into the image under `/etc/grafana/dashboards/mneme/` (config path, not a bind-mount target — the v1.1 baked-vs-state separation already established for Grafana), so no `/volume1` path, no UID concern, no ACL-restart-loop surface. This feature touches none of the DSM frictions that dominated F001–F004.

---

## Constitution Check

Measured against [`constitution.md`](../../.specify/memory/constitution.md) **v1.3.0**.

| Constraint | Status | Notes |
|---|---|---|
| I. Upstream-First, Thin Customization | ✅ Pass | No new image. The one custom image (Grafana) gains two baked dashboard JSONs — exactly the repo-owned-config-that-can't-be-mounted case Principle I carves out for Grafana. No fork. |
| II. Declarative Configuration | ✅ Pass | Both dashboards are committed JSON, baked at build time, provisioned read-only (`allowUiUpdates: false`, `editable: false`). No UI-clicked dashboards; the running Grafana is a cache of the repo. |
| III. Host Networking by Default | N/A | No new service, no new port. `docs/ports.md` unchanged. |
| IV. Resource Discipline | ✅ Pass | No runtime service added — baked JSON only. Metrics 600M and logs/RUM 500M caps both **untouched** (FR-68). Negligible image-size increase. |
| V. Silent-by-Default Alerting | ✅ Pass — by omission | No alert rules (logs/RUM alerting is the dedicated alerting feature). Dashboards are the observation surface — exactly Principle V's "dashboards, not notifications." |
| v1.1 §DSM UID restriction | N/A | No `/volume1` write. Dashboards bake to `/etc/grafana/` (config path). |
| v1.1 §Separate baked config from persisted state | ✅ Pass | Dashboards under `/etc/grafana/dashboards/` (baked config); Grafana state stays at the bind-mounted `/var/lib/grafana`. New files sit in the already-correct path — no masking. |
| v1.1 §Grafana datasource UIDs must be explicit | ✅ Pass | Panels reference `{type: loki, uid: loki}` and `{type: prometheus, uid: prometheus}` by explicit UID — no name-based refs, no auto-UID. |
| v1.2 §Per-application dashboards / Architecture B | ✅ Pass | Both dashboards live in *this* repo under `docker/grafana/dashboards/mneme/`, baked at build time, `foldersFromFilesStructure` → Mneme folder. Tier-1 tag = `mneme`, Tier-2 = facet. Exactly the Architecture B contract. |
| v1.3 §Observability coverage (logs + RUM) | ✅ Pass | Visualizes frontend RUM (Faro) + backend logs (pino + postgres) through the one Grafana — the coverage v1.3 names, now curated rather than Explore-only. |
| v1.3 §Observability scope boundaries (no APM) | ✅ Pass | No traces (F004 drops them at the receiver); these dashboards visualize only the accepted logs/exceptions/events/measurements. No Tempo. |

**Violations:** none. This is a **compliance-check feature, not an amendment** (confirmed at orientation): every constraint it touches is already satisfied by v1.2 Architecture B + v1.3 coverage.

---

## Project Structure

### Files introduced / modified by this feature

```
nas-observability/
├── VERSION                                          # MODIFIED — 0.3.0 → 0.4.0 (FR-67; tag-clobber discipline)
├── docker-compose.yml                               # MODIFIED — grafana image pin v0.3.0 → v0.4.0
│
├── docker/grafana/dashboards/mneme/
│   ├── frontend.json                                # NEW — Mneme — Frontend (uid mneme-frontend)
│   └── backend-logs.json                            # NEW — Mneme — Backend Logs (uid mneme-backend-logs)
│
└── (optional, D8) .github/workflows/build-grafana-image.yml   # MODIFIED — tag-clobber guard (Phase 4, optional)
```

No `config/`, no `docs/` runbook, no `scripts/` change, no `.env` change. The contrast with F004's file list is the point: this is a visualization-only feature.

### Existing files this feature deliberately does NOT touch

- `docker/grafana/provisioning/datasources/datasources.yaml` — the `uid: loki` datasource is consumed as-is (FR-68).
- `docker/grafana/provisioning/dashboards/dashboards.yaml` — `foldersFromFilesStructure: true` already picks up new files in `mneme/`; no provisioner change.
- `docker/grafana/Dockerfile` — `COPY dashboards/ /etc/grafana/dashboards/` already globs the new files; `inject-build-metadata.sh` only stamps `stack/stack-health.json`, so the two new dashboards need no build-time injection.
- `docker-compose.logs.yml`, `config/loki/*`, `config/alloy/*`, `docs/ports.md`, `scripts/init-nas-paths.sh` — all untouched (FR-68).
- The seven existing dashboards — render-unchanged is an acceptance gate (Scenario 1 / NFR-24).

### What this feature does NOT introduce

- No new Loki labels / no relabeling (FR-64 — query-time `| logfmt`/`| json` only).
- No template variables (Spec D5 — `templating.list: []`, matching the existing seven).
- No alert rules / Loki ruler (separate future feature).
- No `client_errors_total` panel (counter removed in Mneme F012 — FR-66).
- No frontend symbolication (deferred; minified-stack caption only — FR-66).
- No runtime service, datasource, port, or backend change (FR-68).

---

## Dashboard & query design (draft — every query frozen against live Loki in Phase 0)

> **Discipline:** the LogQL below is the *design*, authored from the known signal shapes. Phase 0 (T108) runs each query against the running Loki and corrects label keys, field names, the echo prefix, the pino level encoding, and the postgres pattern **before** they're frozen into JSON. Marked-uncertain items are called out inline as `⚠ FREEZE`.

### Dashboard A — `Mneme — Frontend` (`docker/grafana/dashboards/mneme/frontend.json`)

`uid: mneme-frontend` · tags `["mneme","frontend"]` · all panels `{type: loki, uid: loki}`, `service_name="mneme-frontend"`. Layout: a top stat row (exceptions, sessions, vitals at-a-glance), then exception panels, then web-vitals, then events/browser.

| # | Panel | Type | Draft LogQL | Notes |
|---|---|---|---|---|
| 1 | Total exceptions (range) | stat | `sum(count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" [$__range]))` | **Echo-dedup by value-prefix (D2/FR-61).** `noValue: "No frontend exceptions in range — this is the healthy state"`. |
| 2 | Exception rate | timeseries | `sum(count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" [$__auto]))` | Same dedup. Low fill, single series. |
| 3 | Top exception messages | table | `topk(10, sum by (value) (count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" \| logfmt [$__range])))` | ⚠ FREEZE the `value` field name. Dedup before `\| logfmt`. |
| 4 | React error-boundary errors | logs (or table) | `{service_name="mneme-frontend"} \|= "kind=exception" \| logfmt \| context_source="react_boundary"` | **Echo-safe by construction** (echoes carry no `context_source`) — no `!= "console.error:"` needed. Surface `context_componentStack` as a column/field. |
| 5 | Exception detail | logs | `{service_name="mneme-frontend"} \|= "kind=exception" != "console.error:"` | Caption text panel: *"Stacks are minified/unsymbolicated (e.g. `index-*.js:line:col`) — source-map symbolication is a deferred feature."* |
| 6 | Web-vitals p75 (×5) | timeseries (one panel per vital, own axis/thresholds) | `quantile_over_time(0.75, {service_name="mneme-frontend"} \| logfmt \| <field> != "" \| unwrap <field> [$__auto])` | See **Web-vitals** below — per-metric field + CWV thresholds. ⚠ FREEZE `value_<vital>` vs bare `<vital>`. |
| 7 | Sessions started | stat + timeseries | `sum(count_over_time({service_name="mneme-frontend"} \|= "kind=event" \| logfmt \| <session_start filter> [$__range]))` | ⚠ FREEZE the session_start event discriminator (`event_name`? `type`?). |
| 8 | Navigation by page | table | `topk(10, sum by (page_url) (count_over_time({service_name="mneme-frontend"} \|= "kind=event" \| logfmt [$__range])))` | `page_url` parsed query-time, not a label (FR-64). |
| 9 | Browser breakdown | piechart/table | `sum by (browser_name) (count_over_time({service_name="mneme-frontend"} \| logfmt [$__range]))` | ⚠ FREEZE `browser_name` field name (`browser_*` family). |

### Dashboard B — `Mneme — Backend Logs` (`docker/grafana/dashboards/mneme/backend-logs.json`)

`uid: mneme-backend-logs` · tags `["mneme","backend","logs"]` · `service_name=~"mneme-(api|worker|postgres)-1"`. Layout: **three rows** — api, worker, postgres — because of the format split (D7). A top summary row spans all three; the postgres row diverges on parsing.

| # | Panel | Type | Draft LogQL | Notes |
|---|---|---|---|---|
| 1 | Log volume by level (api+worker) | timeseries | `sum by (level) (count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json [$__auto]))` | ⚠ FREEZE pino level encoding — **pino defaults to NUMERIC levels** (`30`=info, `40`=warn, `50`=error, `60`=fatal). If numeric, map them in field overrides; the error filter is `level>=40`, not `level="error"`. Confirm live. |
| 2 | Error+warn rate (api+worker) | stat | `sum(count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json \| level>=40 [$__range]))` | Depends on #1's encoding. `noValue: "No backend errors/warnings in range — healthy"`. |
| 3 | Top error messages (api+worker) | table | `topk(10, sum by (msg) (count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json \| level>=50 [$__range])))` | ⚠ FREEZE `msg` field name. |
| 4 | Live log stream (all three) | logs | `{service_name=~"mneme-(api\|worker\|postgres)-1"}` | **Raw logs panel — no field extraction**, so postgres renders fine here (D7: raw stream "just works"). |
| 5 | Errors only (app rows) | logs | `{service_name=~"mneme-(api\|worker)-1"} \| json \| level>=40` | App-only; postgres errors are panel #7. |
| 6 | api row / worker row split | logs | `{service_name="mneme-api-1"}` / `{service_name="mneme-worker-1"}` | Per-container scoping (FR-62). |
| 7 | Postgres severity + errors | logs + (optional) timeseries | logs: `{service_name="mneme-postgres-1"}`; severity count: `{service_name="mneme-postgres-1"} \| pattern "<_>:  <severity>:  <_>"` or `\|~ "ERROR\|FATAL\|WARNING"` | **Postgres-specific parsing (D7).** ⚠ FREEZE the `log_line_prefix` → the `\| pattern` template depends on Mneme's postgres logging config. Fallback: raw logs + `\|~ "ERROR\|FATAL"` count, never `\| json`. |

### Console-echo dedup (Spec D2 / FR-61) — the correctness keystone

Every headline exception-count panel (A1, A2, A3, A5) carries `!= "console.error:"`. This is **documented in-JSON** via each panel's `description` field so a future editor can't "simplify" it back to a `kind` filter:

> *"Dedup: excludes Faro's captureConsole echo, which is `kind=exception` (same kind as the real error) with `value` prefixed `console.error:`. Do NOT replace with a `kind` or `detected_level` filter — the echo shares the kind, and `detected_level` is a Loki heuristic, not a contract. The `console.error:` value-prefix is the only deterministic separator. See spec.md D2."

The React-boundary panel (A4) is explicitly **exempt** — its `context_source="react_boundary"` filter excludes echoes by construction. Scenario 2 is the falsifiable test: trigger one error, A1 must read **1**, not 2.

### Web-vitals (Spec settled inputs #2, #3) — per-metric, standard CWV thresholds

Web-vitals arrive as Loki measurements (`kind=measurement type=web-vitals`), one vital per record, value in the body — **not** Prometheus histograms. Each vital is its own timeseries panel (own axis, own thresholds) because the scales differ by orders of magnitude. p75 via `quantile_over_time(0.75, ... | unwrap <field> [$__auto])`.

**⚠ FREEZE — two field-name candidates, confirm live:** live data showed **both** `cls=0.000016` (rounded bare) **and** `value_cls=1.62e-05` (full-precision `value_*`). Phase 0 confirms which is canonical for the `unwrap`, and verifies `| logfmt | unwrap value_<vital>` returns **numerics** (logfmt-extracted strings sometimes need type coercion before `unwrap` feeds `quantile_over_time`). Default assumption: the `value_*` field is the precision-preserving one to unwrap — but **verify, don't assume**.

**Per-metric thresholds — the official Core Web Vitals boundaries** (good / needs-improvement / poor), one config per panel:

| Vital | Field (⚠ freeze) | Unit | Good < | Poor ≥ |
|---|---|---|---|---|
| LCP | `value_lcp` | s (ms→s) | 2.5s | 4s |
| CLS | `value_cls` | unitless | 0.1 | 0.25 |
| INP | `value_inp` | ms | 200ms | 500ms |
| FCP | `value_fcp` | s (ms→s) | 1.8s | 3s |
| TTFB | `value_ttfb` | ms | 800ms | 1.8s |

Grafana threshold steps per panel: green below "good", yellow in the needs-improvement band, red at "poor". No invented thresholds.

### Cardinality & no-template-vars (Spec D5 / FR-64)

`templating.list: []` on both dashboards (matching the existing seven). Every non-label field (`value`, `context_*`, `page_url`, `browser_*`, `session_id`, `value_*`, pino `level`/`msg`) is extracted **query-time** via `| logfmt`/`| json`. The dashboards introduce **zero** new Loki labels — they are read-only consumers, so Scenario 7 (no label growth) holds by construction. A `session_id`/`page_url` filter variable is YAGNI now, additive later.

---

## Deploy mechanics (FR-67) — image-bake, clean VERSION bump

Same path as F004's T097/T098 Loki-datasource bake:

1. **Author** `frontend.json` + `backend-logs.json` under `docker/grafana/dashboards/mneme/`.
2. **Bump `VERSION` 0.3.0 → 0.4.0** — mandatory. Baked content changing without a `VERSION` bump re-pushes a mutable tag (F004 retro **fix-chain #4 / tag-clobber**). New baked content always gets a new tag.
3. **Repin** `docker-compose.yml` `grafana:` → `ghcr.io/.../grafana:v0.4.0`.
4. The `build-grafana-image` workflow fires on the `docker/grafana/**` path filter, builds, and pushes `grafana:v0.4.0` + `grafana:sha-<sha>`.
5. **Redeploy** the metrics stack via Portainer ("redeploy with new image").
6. **No-regression check** (Scenario 1 / NFR-24): both new dashboards present in the Mneme folder, all panels Loki-backed and rendering; the seven existing dashboards render unchanged; both datasources healthy.

**Optional harden-while-here (Spec D8 — Phase 4, decide at task time):** add a CI step to `build-grafana-image.yml` that queries the GHCR tags API and **fails the build if `grafana:v${VERSION}` already exists** on a content-changing push — machine-enforcing the bump discipline fix-chain #4 violated. This is the *second* Grafana-image change since that lesson, so it's a reasonable place to land it; but it's strictly optional and can defer to a standalone hardening change. **Flagged either way, not silently dropped.**

---

## Implementation Phases

Decomposed in [`tasks.md`](./tasks.md) (next). Tasks continue F004's sequence from **T108** (F004 ended T107). FRs FR-59–FR-68, NFRs NFR-23–NFR-25 are already assigned in the spec. High-level shape:

**0. Freeze queries against live Loki** (the consequential pre-flight — F004-Phase-0 analog). Run every draft query against the running Loki and confirm/correct, before any JSON is frozen:
   - Label keys: `service_name="mneme-frontend"` and `service_name=~"mneme-(api|worker|postgres)-1"` (both `container` and `service_name` exist on backend — confirm `service_name` carries the expected values).
   - **Echo dedup:** trigger/observe a real exception + its `console.error:` echo; confirm `!= "console.error:"` separates them and the count halves correctly.
   - **Web-vitals:** which field (`value_cls` vs `cls`) is canonical; `| unwrap` returns numerics for `quantile_over_time`.
   - **Pino level encoding:** numeric (`30/40/50`) vs string — sets the `level>=40` vs `level="error"` filter and the field-override mappings.
   - **Postgres severity:** the `log_line_prefix` shape → the `| pattern` template (or fall back to `|~ "ERROR|FATAL"`).
   - **Field names:** `value` (exception message), `context_source`/`context_componentStack`, `msg`, `page_url`, `browser_name`, session_start discriminator.

**1. Author `frontend.json` + verify against live data.** Hand-authored compact JSON to the repo model (schemaVersion 39, gridPos style, UID-keyed datasource, `editable:false`, `templating.list:[]`). Echo-dedup in-JSON descriptions; `noValue` on error panels; minified-stack caption. Verify each panel renders against live frontend telemetry (Scenarios 2–4, 6).

**2. Author `backend-logs.json` + verify.** Three rows (api/worker pino JSON + postgres mixed-format per D7). `noValue` on the error/warn stat. Verify api/worker level aggregation and the postgres raw-stream + severity path both render (Scenario 5); confirm postgres is never silently empty from a `| json` miss.

**3. VERSION bump + image rebuild + redeploy + no-regression.** `VERSION` 0.3.0→0.4.0, `docker-compose.yml` repin, let CI rebuild, redeploy, confirm Scenario 1 / NFR-24 (new dashboards present, seven existing unregressed, datasources healthy). No tag-clobber.

**4. (Optional) tag-clobber CI guard (Spec D8).** Decide include-or-defer; if included, add the GHCR-tag-exists check to `build-grafana-image.yml`. Flag the decision in the PR either way.

**5. DS224+ acceptance walk-through.** Operator-driven pass over Scenarios 1–8: dashboards present, echo-dedup correct (the key test), boundary panel with componentStack, vitals with CWV thresholds, postgres logs surfaced, empty-state reads healthy, no label growth, clean redeploy.

**No 24-hour stability observation.** Unlike F002–F004, F005 adds **no runtime service** — only baked dashboard JSON. There is nothing to soak: the deploy is the rebuilt Grafana image, and "does it work" is fully answered by the Phase 5 walk-through (deploy-and-verify, not soak). This is a deliberate scope call, stated so its absence reads as reasoned, not forgotten.

Phase 0 is the discipline analog of F003's T075 metric-name verification and F004's Phase 0 capability gates: **don't ship queries against unverified field names.** It is the single most important phase in this feature.

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| **Console-echo dedup wrong → every error count doubles** | Medium — the subtle one | D2/FR-61: `!= "console.error:"` value-prefix on every count panel; documented in-JSON so it isn't "simplified" away; Scenario 2 is the falsifiable test (one error → count of 1). Phase 0 confirms the prefix against real echo data. |
| Web-vitals field name assumed wrong (`cls` vs `value_cls`) → `unwrap` returns nothing or rounded garbage | Medium | Phase 0 confirms the canonical field live and that `unwrap` yields numerics for `quantile_over_time`. Two candidates explicitly disambiguated, not assumed. |
| Postgres logs silently empty because `\| json` failed on plain text | Medium | D7: postgres row uses raw-logs (no extraction) + `\| pattern`/`\|~` severity, never `\| json`. FR-63 forbids a silent "no data" from a JSON miss. Phase 0 freezes the `log_line_prefix` pattern. |
| Pino level is numeric, error filter written as `level="error"` → empty error panels | Medium | Phase 0 confirms the encoding; default to `level>=40` (numeric) with field-override label mappings. |
| Grafana image rebuild regresses an F001–F003 dashboard | Low | Existing build verification + Scenario 1/NFR-24 confirm the seven render unchanged and datasources stay healthy post-`v0.4.0`. |
| Tag-clobber: VERSION not bumped, mutable tag re-pushed | Low — but the named prior incident | FR-67 makes the bump mandatory; optional CI guard (D8) machine-enforces it. The retro lesson is explicitly in-scope here. |
| Empty error panels read as "broken" not "healthy" | Low | FR-65 `noValue` text on every error/exception panel; Scenario 6 verifies the quiet-period reading. |
| Future editor "simplifies" the echo-dedup back to a kind filter | Low | In-JSON `description` on each dedup panel explains why the prefix-exclusion is load-bearing and points to spec.md D2. |

---

## Dependencies

**F004 complete and live (2026-05-31)** — Loki + Alloy deployed, the `uid: loki` datasource baked into Grafana `v0.3.0`, backend logs (pino + postgres) and frontend RUM (Faro) both verified flowing into Loki on real traffic. F005 consumes this substrate unchanged; it is the reason the dashboards have data to render.

**Constitution v1.3.0 + v1.2 Architecture B** — v1.3's logs/RUM coverage and v1.2's per-application-dashboards-in-this-repo are what make F005 a compliance-check feature rather than an amendment. No constitutional change.

**Mneme F012 (frontend) + F008 (backend) shipping live** — the *producers* of the telemetry. They already emit into Loki via F004's pipeline; F005 needs **no** further Mneme change. The frontend signal shapes are documented in Mneme's `faro-verification.md` (the queries F005 freezes); the backend pino/postgres shapes are confirmed in Phase 0 against live Loki.

**No downstream blockers** — F005 ships independently. It adds observation surface; nothing waits on it. (A future logs/RUM *alerting* feature may build on these query patterns, but does not depend on the dashboards existing.)
