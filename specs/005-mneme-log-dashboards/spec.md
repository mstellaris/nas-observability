# Feature Specification: Mneme Log Dashboards (Frontend RUM + Backend Logs)

**Feature Branch:** `005-mneme-log-dashboards`
**Status:** Draft (2026-05-31) — pending `/plan`
**Created:** 2026-05-31
**Depends on:** Feature 004 complete (2026-05-31, Grafana **v0.3.0** with the baked Loki datasource live and verified); **Constitution v1.3.0** (unified observability — metrics + logs + RUM; Architecture B per-application dashboards baked into the custom Grafana image). Mneme's **F012** (frontend Faro Web SDK adoption) and **F008** (backend pino logging) are the **producers** of the telemetry these dashboards visualize — both are already shipping live into Loki via F004's Alloy/Faro pipeline. This feature consumes that live data; it does **not** depend on any further Mneme change.

---

## Overview

Feature 005 turns the Loki-backed telemetry that F004 made *explorable* into **standing, curated Grafana dashboards** for the Mneme application — the follow-up F004 explicitly deferred ("curated logs/RUM dashboards can follow once query patterns settle"). It adds two new dashboards to the existing `mneme/` folder, alongside the three F003 Prometheus-backed dashboards (api, worker, database), under the Architecture B convention: per-application dashboards live in *this* repo under `docker/grafana/dashboards/<consumer-slug>/`, baked into the custom Grafana image at build time.

The two new dashboards are split by **tier**, mirroring the existing api/worker/database tier splits — **not** by signal type. Both are Loki-backed (frontend RUM is logs too — every signal lands in Loki as a log stream); the clean mental model is *frontend vs. backend*, not *RUM vs. logs*:

- **Mneme — Frontend** — the browser tier. Faro telemetry under `service_name="mneme-frontend"`: exceptions (uncaught, unhandled-rejection, React error-boundary), web-vitals (CLS/LCP/INP/FCP/TTFB), and session/navigation events. Freezes the ad-hoc queries from Mneme's F012 `faro-verification.md` into standing panels.
- **Mneme — Backend Logs** — the server tier. Container-stdout logs for all three backend containers — `mneme-api-1`, `mneme-worker-1`, `mneme-postgres-1` — discovered by Alloy's `loki.source.docker` and queryable by `service_name`. Complements (does not duplicate) the F003 Prometheus backend-metrics dashboards: metrics say *that* latency spiked; these logs say *why*.

These are the **first Loki-backed dashboards in the repo** — all seven existing dashboards are Prometheus-backed. They establish the per-application *log*-dashboard pattern, exactly as F003 established the per-application *metrics* pattern and F004 established the logs/RUM *subsystem*. The only change to the running stack is baked dashboard JSON in the custom Grafana image (a `VERSION` bump + rebuild + redeploy); no compose service is added, no datasource changes, no new ports, no backend touched.

**This feature is read-only visualization.** It introduces no new Loki labels (cardinality discipline from the F004 retro: `service_name`/`container` are the only labels; every other field is parsed query-time via `| logfmt` / `| json`), no alert rules (alerting on logs/RUM remains a separate future feature), and no frontend-stack symbolication (exception stacks stay minified — source-map symbolication is a documented deferred feature).

---

## User Scenarios & Testing

### Primary User Story

As Stellar, when Mneme misbehaves I want a curated Grafana view for each tier — one click to "what errors is the browser throwing, and are the web-vitals healthy?" and one click to "what are the api/worker/postgres containers logging right now?" — instead of hand-typing LogQL into Explore every time. The metrics dashboards already tell me *that* something spiked at 14:03; these tell me *what the browser saw* and *what the server logged* at 14:03, in the same pane of glass, with the queries already correct (including the error-count dedup I'd otherwise get wrong by hand).

### Acceptance Scenarios

**Scenario 1: Both dashboards provision into the Mneme folder, Loki-backed**

**Given** the custom Grafana image is rebuilt at the new `VERSION` with the two new JSON files baked under `docker/grafana/dashboards/mneme/`
**When** the operator redeploys the metrics stack and opens Grafana
**Then** "Mneme — Frontend" and "Mneme — Backend Logs" appear in the **Mneme** folder alongside the three F003 dashboards
**And** every panel's datasource resolves to `{type: loki, uid: loki}` and renders without a datasource error
**And** the existing seven F001–F003 dashboards render unchanged (no regression from the image rebuild)

**Scenario 2: Frontend exception count is correct — the console-echo is NOT double-counted**

**Given** Mneme's Faro `captureConsole` emits, for every thrown error, a **second** `kind=exception` stream whose `value` is prefixed `console.error:` (verified live — the echo is the *same kind* as the real exception, with a *different content hash*, so neither a `kind` filter nor a hash-dedup separates them — D2)
**When** the operator views the frontend exception-count / exception-rate panels, which exclude the echo by the **`console.error:` value-prefix** (`!= "console.error:"`, not a `kind` or `detected_level` filter)
**Then** one triggered frontend error shows as **one** exception, not two
**And** the count does not silently double when Faro's console-capture is on

**Scenario 3: React error-boundary panel surfaces boundary errors with their component stack**

**Given** real boundary errors carry `context_source="react_boundary"` **and** `context_componentStack` as distinct fields, while the console echo carries neither
**When** the operator views the React-boundary panel (filtered `context_source="react_boundary"`)
**Then** boundary errors appear with `context_componentStack` surfaced as a distinct field
**And** the panel is echo-safe **by construction** (echoes have no `context_source`, so no extra dedup is needed here)

**Scenario 4: Web-vitals are visualized across the five metrics**

**Given** Faro emits `kind=measurement type=web-vitals` for CLS, LCP, INP, FCP, TTFB
**When** the operator views the web-vitals panel(s)
**Then** all five vitals render over the selected range
**And** they carry good / needs-improvement / poor thresholds so health is readable at a glance

**Scenario 5: Backend-logs dashboard covers all three backend containers by `service_name`**

**Given** `mneme-api-1`, `mneme-worker-1`, and `mneme-postgres-1` all ship stdout to Loki, each stream carrying both `container` and `service_name` labels (verified — same value on both)
**When** the operator views the Backend Logs dashboard
**Then** logs for all three containers are queryable by **`service_name`** (the chosen label key, consistent with the frontend dashboard's `service_name="mneme-frontend"`)
**And** api/worker pino JSON parses for `level`/`msg`, and Postgres's plain-text logs are still surfaced (mixed-format handling resolved in `/plan` — D7)
**And** a per-container split (api / worker / postgres) lets the operator scope to one tier

**Scenario 6: Empty error panels read as "healthy," not "broken"**

**Given** at single-user scale the normal state is **zero** frontend exceptions and zero backend error logs in a typical range
**When** the operator opens the dashboards during a quiet period
**Then** the exception/error panels show a sensible `noValue` message (e.g. "No frontend exceptions in range — this is the healthy state"), consistent with how the existing Mneme dashboards present absent data
**And** an empty panel is not mistaken for a broken query

**Scenario 7: No new Loki labels are introduced**

**Given** the cardinality discipline established in F004 (only `service_name`/`container` are labels; everything else stays in the log body)
**When** these dashboards are deployed and queried
**Then** Loki's label set is unchanged — every non-label field (`session_id`, `browser_*`, `page_url`, `value_*`, `context_*`, pino fields) is extracted **query-time** via `| logfmt` / `| json`
**And** stream cardinality does not grow as a result of this feature (these are read-only consumers)

**Scenario 8: Deploy follows the image-bake path with a clean VERSION bump**

**Given** adding files under `docker/grafana/dashboards/` triggers the `build-grafana-image` workflow (path filter `docker/grafana/**`)
**When** the feature lands
**Then** `VERSION` is bumped (0.3.0 → **0.4.0**), `docker-compose.yml` repins `grafana:` to the new tag, the image is rebuilt, and the metrics stack is redeployed
**And** the new tag is **not** a re-push of an existing tag (the F004 retro tag-clobber lesson — fix-chain #4 — is honored)

### Edge Cases

- **Console-echo double-count (the critical one).** The echo is `kind=exception`, identical kind to the real exception, with a different content hash — so the intuitive "filter by kind" and "dedup by hash" both fail. The deterministic separator is the **`console.error:` `value` prefix**. All headline error-count panels exclude it; `detected_level` (unknown vs. error) is Loki's heuristic classification, **not** a contract, and MUST NOT be the dedup mechanism. [D2]
- **Postgres logs are not pino JSON.** `mneme-postgres-1` emits Postgres's standard plain-text log format, not JSON — so `| json` parses api/worker but not postgres. `/plan` resolves mixed-format handling (e.g. per-row parsing: `| json` for app rows, a `| logfmt`/`| pattern`/regex or raw-line panel for postgres; or rely on the panel being a logs panel that needs no field extraction). The api/worker/postgres row split is partly *motivated* by this format difference. [D7]
- **Minified, unsymbolicated stacks.** Frontend exception stacks reference bundled assets (`index-jQk4oDYt.js:29:53618`) — verified. Source-map symbolication is a deferred future feature; the exception-detail panel includes a short text-panel caption noting stacks are minified, so the operator isn't surprised. [D6, settled input #2]
- **Quiet period / no data.** The healthy steady state is empty error panels. Without `noValue` text they read as broken queries. Scenario 6 / D6 handle this.
- **Image rebuild regresses an existing dashboard.** The rebuild that bakes the two new JSONs must not break the seven existing dashboards or the datasource health. Scenario 1 confirms; same guard as F004 Scenario 7.
- **Tag-clobber if `VERSION` not bumped.** Baked Grafana content changing without a `VERSION` bump re-pushes a mutable tag (F004 fix-chain #4). The plan MUST bump `VERSION`; an optional CI guard is considered (D8).
- **Label-key drift on backend logs.** Both `container` and `service_name` exist on backend streams; the dashboards standardize on `service_name`. If a future Alloy relabel changed this, the panels would break — `/plan` freezes the queries against live Loki and the label choice is documented (D3).
- **Web-vitals as logs, not metrics.** Web-vitals arrive as Loki log measurements (`value_*` fields in the body), not Prometheus metrics — so panels aggregate them query-time via `| logfmt | unwrap`. `/plan` fixes the exact LogQL (e.g. `quantile_over_time` for p75). Not a Prometheus histogram.

---

## Requirements

### Functional Requirements

- **FR-59:** The system MUST add **two** dashboard JSON files under `docker/grafana/dashboards/mneme/` — `frontend.json` (title `Mneme — Frontend`, uid `mneme-frontend`, tags `["mneme","frontend"]`) and `backend-logs.json` (title `Mneme — Backend Logs`, uid `mneme-backend-logs`, tags `["mneme","backend","logs"]`). Both MUST follow the repo's established model: `schemaVersion: 39`, `editable: false`, `id: null`, `version: 1`, UID-keyed datasource refs `{type: loki, uid: loki}` at panel and target level, em-dash titles, and `templating.list: []` (no template variables — FR-64). The split is by **tier (frontend vs. backend)**, named by tier, NOT by signal type (both are logs). [Constitution v1.2 Architecture B; v1.3 Observability coverage; settled input #1]
- **FR-60:** The **Mneme — Frontend** dashboard MUST visualize, from `service_name="mneme-frontend"`: (a) **exception rate** (timeseries) and **total exceptions** (stat); (b) **top exception messages** (table); (c) a **React error-boundary** panel filtered `context_source="react_boundary"`, surfacing `context_componentStack`; (d) an **exception-detail** logs panel with a text caption noting stacks are minified/unsymbolicated; (e) **web-vitals** (CLS/LCP/INP/FCP/TTFB from `kind=measurement type=web-vitals`) with good/needs-improvement/poor thresholds; (f) **sessions/navigation** (`kind=event` — session_start rate, distinct `session_id`, navigation by `page_url`) and a **browser breakdown** (`browser_*`). [Mneme F012 signals; settled input #1]
- **FR-61:** Every headline exception-count / exception-rate panel on the Frontend dashboard MUST exclude the Faro console-echo by the **`console.error:` `value`-prefix** (`!= "console.error:"`, or post-`| logfmt` filtering where the parsed `value` does not start with `console.error:`). It MUST NOT rely on a `kind` filter (the echo is `kind=exception`, same kind as the real exception) and MUST NOT rely on `detected_level` (a Loki heuristic, not a contract). The React-boundary panel (FR-60c) is echo-safe by construction and needs no extra dedup. [D2 — settled input #2, overturns the original kind-filter approach]
- **FR-62:** The **Mneme — Backend Logs** dashboard MUST cover **all three** backend containers — `mneme-api-1`, `mneme-worker-1`, `mneme-postgres-1` — keyed on **`service_name`** (e.g. `service_name=~"mneme-(api|worker|postgres)-1"` or equivalent), the same label key the Frontend dashboard uses. It MUST provide: log-volume-by-level (timeseries), an error+warn rate stat, a live log-stream panel, an errors-only logs panel, and top error messages (table); and SHOULD provide an api/worker/postgres row split. [settled inputs #3, #4]
- **FR-63:** The Backend Logs dashboard MUST surface **Postgres** logs (slow queries, errors, connection issues) despite their plain-text (non-pino-JSON) format. Parsing MUST handle the mixed-format reality — `| json` for the api/worker pino rows; a non-JSON-safe approach for the postgres row (logs panel / `| logfmt` / `| pattern` / regex, decided in `/plan`). A panel MUST NOT silently show "no data" for postgres merely because `| json` failed on its lines. [D7 — settled input #4]
- **FR-64:** Both dashboards MUST introduce **no new Loki labels** and MUST keep `templating.list: []` (no template variables in v1, consistent with the existing seven dashboards). All non-label fields are extracted **query-time** via `| logfmt` / `| json`; only `service_name`/`container` remain labels (F004 cardinality discipline). A `session_id`/`page_url` filter variable is YAGNI at single-user scale and additive later. [F004 retro cardinality discipline; settled inputs #5, #1]
- **FR-65:** The error/exception panels (frontend exceptions; backend error/warn) MUST set a sensible **`noValue`** empty-state message (e.g. "No frontend exceptions in range — this is the healthy state") so an empty panel reads as *healthy* (the normal single-user state), not *broken* — consistent with how the existing Mneme dashboards present absent data. [settled input #6]
- **FR-66:** The feature MUST NOT add a `client_errors_total` panel (the backend counter was removed in Mneme F012; frontend errors live in Loki only) and MUST NOT attempt frontend-stack symbolication (deferred future feature — the exception-detail panel notes stacks are minified). [Mneme F012; settled inputs as proposed]
- **FR-67:** Deploy MUST follow the image-bake path: bump `VERSION` **0.3.0 → 0.4.0**, repin `docker-compose.yml` `grafana:` to `v0.4.0`, let the `build-grafana-image` workflow rebuild + publish (triggered by the `docker/grafana/**` path filter), and redeploy the metrics stack via Portainer. The new tag MUST NOT re-push an existing tag (F004 retro fix-chain #4 — tag-clobber). The image rebuild MUST NOT regress the seven existing dashboards or datasource health (Scenario 1). [F004 T097/T098 deploy path; retro version-hygiene lesson]
- **FR-68:** This feature MUST NOT change the metrics subsystem beyond the Grafana image rebuild: no compose service added/removed, no datasource change (Loki `uid: loki` already exists from F004), no new host ports, no backend change, no Loki/Alloy config change. The 600 MB metrics cap and 500 MB logs/RUM cap are untouched. [Constitution v1.3 Principle IV; FR-67]

### Non-Functional Requirements

- **NFR-23:** Each panel's LogQL query SHOULD render within the dashboard-baseline budget — a typical single-container / last-1h query returns within ~3 s (matching F004 NFR-20 and the F002/F003 dashboard-render baseline). Aggregations over the full retention window MAY be slower and are not the common case. [F004 NFR-20]
- **NFR-24:** Baking the two dashboards and rebuilding the Grafana image MUST NOT regress metrics-subsystem startup, datasource health, or the rendering of the seven existing dashboards. Verified post-deploy (Scenario 1). [F004 NFR-22 analog]
- **NFR-25:** Panels MUST be legible at single-user data volumes — including the empty state (NFR via FR-65 `noValue`) and low-cardinality real data — without requiring template-variable filtering to be usable.

### Key Entities

- **`docker/grafana/dashboards/mneme/frontend.json`** — the browser-tier dashboard. uid `mneme-frontend`, tags `["mneme","frontend"]`, Loki-backed, all panels query `service_name="mneme-frontend"`. Panels per FR-60; console-echo dedup per FR-61.
- **`docker/grafana/dashboards/mneme/backend-logs.json`** — the server-tier dashboard. uid `mneme-backend-logs`, tags `["mneme","backend","logs"]`, Loki-backed, covers api/worker/postgres by `service_name`. Panels per FR-62/FR-63.
- **Console-echo dedup rule** — the `!= "console.error:"` value-prefix exclusion (FR-61). The single most important correctness detail in this feature; documented in the dashboard JSON via a query comment or panel description so a future editor doesn't "simplify" it back to a kind filter.
- **Loki datasource (`uid: loki`)** — pre-existing from F004; consumed unchanged. No datasource work in this feature.
- **Grafana image `v0.4.0`** — the only deployed artifact: the existing custom image rebuilt with two added baked dashboards. `VERSION` 0.3.0 → 0.4.0; `docker-compose.yml` repinned. [FR-67]

---

## Specific Decisions (resolved in this spec)

### D1. Two dashboards, split by tier, named by tier
Frontend vs. backend — `Mneme — Frontend` and `Mneme — Backend Logs` — consistent with the existing api/worker/database tier splits. **Not** "RUM vs. logs": both are Loki log streams; framing them by signal type would muddy the model. One dashboard per tier matches the existing one-dashboard-per-facet pattern and keeps each focused. [Settled input #1]

### D2. Console-echo dedup is a `value`-prefix exclusion, NOT a kind/level filter
**This overturns the orientation's proposed approach.** Verified against live data: Faro's `captureConsole` emits a *second* `kind=exception` stream for every thrown error, `value` prefixed `console.error:`, with a *different content hash*. So `kind=exception` matches **both** real and echo (would double-count), and hash-dedup fails (different hashes). The deterministic separator is the value prefix: headline error queries are `{service_name="mneme-frontend"} |= "kind=exception" != "console.error:"` (or the post-`| logfmt` parsed-`value` equivalent). `detected_level` (unknown vs. error) is a Loki heuristic, not a contract — explicitly NOT the dedup mechanism. The React-boundary panel is echo-safe by construction (echoes carry no `context_source`). [Settled input #2]

### D3. Backend-log label key is `service_name`
Backend streams carry **both** `container` and `service_name` (same value, e.g. `mneme-api-1` — verified). The dashboards standardize on **`service_name`** so both the frontend (`service_name="mneme-frontend"`) and backend dashboards use the same label key — one mental model. Deliberate, not defaulted. [Settled input #3]

### D4. Backend-logs dashboard includes Postgres
Scope is all three backend containers — `mneme-api-1`, `mneme-worker-1`, `mneme-postgres-1` — not just api+worker. Postgres logs (slow queries, errors, connection issues) are genuinely new coverage and complement the F003 Postgres *metrics* dashboard. Same panel structure, broader reach; an api/worker/postgres row split is the natural layout. [Settled input #4]

### D5. No template variables in v1
`templating.list: []`, matching the repo's no-template-vars convention across all seven existing dashboards. A `session_id`/`page_url` filter is YAGNI at single-user scale and would make the first Loki dashboards the odd ones out. Additive later if real usage shows the need. [Settled input #5]

### D6. `noValue` empty states + minified-stack caveat
Error/exception panels get `noValue` text so an empty panel (the normal healthy state at single-user scale) reads as "no errors," not "broken" — consistent with the existing Mneme dashboards' intentional empty states. The exception-detail panel carries a text caption that stacks are minified/unsymbolicated (symbolication deferred), so the operator isn't surprised by `index-*.js:line:col` frames. [Settled input #6, #2]

### D7. Mixed-format backend parsing — divergence is in the *aggregation* panels, not the raw stream
api/worker are pino JSON (`| json` works); postgres is plain-text (`| json` does not). The key sharpening: **the divergence is confined to aggregation panels, not raw-stream panels.** A raw **logs panel** needs no field extraction, so postgres's live stream renders fine without `| json` — the postgres row's live-tail "just works." The `| json` parsing only matters for **aggregation** (count-by-level, error-rate), and that's where postgres diverges: it has no pino `level` field, so its severity (`LOG:` / `ERROR:` / `FATAL:` / `WARNING:`) is parsed via `| pattern`/regex instead. So api/worker rows share pino-JSON aggregation; the postgres row is either raw-logs-only **or** uses postgres-specific severity parsing. `/plan` makes this concrete; no panel may silently show "no data" for postgres because `| json` missed. [Settled input → plan item]

### D8. Tag-clobber CI guard — optional, plan-time call
F004 retro carry-forward #1: a CI step failing the `build-grafana-image` build if `v${VERSION}` already exists as a published GHCR tag (machine-enforcing the VERSION-bump discipline that fix-chain #4 violated). This is the *second* Grafana-image change since that lesson. `/plan` decides whether to include it as an optional harden-while-here task or defer — flagged either way, not silently dropped. [F004 retro follow-up #1; settled input #7]

---

## Success Criteria

This feature is complete when:

1. `Mneme — Frontend` and `Mneme — Backend Logs` provision into the Mneme folder, all panels Loki-backed and rendering; the seven existing dashboards render unchanged after the image rebuild.
2. A single triggered frontend error shows as **one** exception (console-echo excluded by the `console.error:` value-prefix), not two.
3. The React-boundary panel shows boundary errors with `context_componentStack`, echo-safe by construction.
4. Web-vitals (CLS/LCP/INP/FCP/TTFB) render with health thresholds; sessions/navigation/browser panels populate.
5. The Backend Logs dashboard shows api/worker/postgres logs keyed on `service_name`, with Postgres's plain-text logs surfaced (not dropped by a JSON-parse miss).
6. Error/exception panels show sensible `noValue` text in quiet periods — empty reads as healthy.
7. No new Loki labels introduced; `templating.list: []`; all non-label fields parsed query-time.
8. `VERSION` 0.3.0 → 0.4.0, `docker-compose.yml` repinned, image rebuilt + redeployed, no tag-clobber.

Explicitly not required for this feature:

- **Alerting on logs/RUM** (Loki ruler, error-rate alerts) — separate future feature.
- **Frontend-stack symbolication** — deferred; stacks stay minified, noted in-panel.
- **Template-variable filtering** — D5; additive later.
- **Any backend/compose/datasource/Loki/Alloy change** — FR-68; this is baked-dashboard-JSON only.
- **A `client_errors_total` panel** — that counter is gone (Mneme F012).

---

## Out of Scope

- **Alerting on logs or RUM** — no Loki ruler, no error-rate rules, no Alertmanager wiring. The dedicated alerting feature owns this.
- **Frontend source-map symbolication** — a documented deferred feature; these dashboards display minified stacks with a caveat.
- **Template variables / ad-hoc filters** — D5; not in v1.
- **New Loki labels / relabeling** — cardinality discipline holds; query-time parsing only (FR-64).
- **Other apps' log dashboards** — F005 establishes the per-app log-dashboard pattern for Mneme; per-app onboarding for future consumers is later work.
- **Backend, compose, datasource, Loki, or Alloy changes** — FR-68. The only deployed artifact is the rebuilt Grafana image.
- **Web-vitals as Prometheus metrics** — they arrive as Loki measurements and are aggregated query-time; no Prometheus recording rules.

---

## Notes for `/plan` and `/tasks`

When this feature is planned, `plan.md` resolves the following (explicitly deferred from this spec):

- **Freeze every LogQL query against live Loki.** Verify the exact label keys (`service_name` on frontend + all three backend containers), the `console.error:` value-prefix dedup against real echo data, the `context_source`/`context_componentStack` field names, and the pino field names (`level`/`msg`) — before freezing panel queries. (F001 lesson: don't assume; confirm live.)
- **Web-vitals field ambiguity (verify live — two candidates to disambiguate).** Live data showed **both** a rounded bare field (`cls=0.000016`) **and** a full-precision `value_*` field (`value_cls=1.62e-05`) for the same vital. `/plan` MUST confirm which field carries the **canonical** value for the `unwrap`, and verify that `| logfmt | unwrap value_<vital>` actually returns **numerics** for `quantile_over_time` (logfmt-extracted fields sometimes need type handling before `unwrap`). Don't assume the field name — confirm against live data.
- **Web-vitals thresholds — the STANDARD Core Web Vitals boundaries, per-metric.** The five vitals have wildly different scales (CLS unitless ~0–0.25; LCP/FCP/TTFB ms in the hundreds–thousands; INP ms in the tens–hundreds), so each needs **its own threshold config and likely its own panel/axis** — not one shared config. Use the official CWV good / needs-improvement / poor boundaries, not invented ones: **LCP** <2.5s / <4s, **CLS** <0.1 / <0.25, **INP** <200ms / <500ms, **FCP** <1.8s / <3s, **TTFB** <800ms / <1.8s. `/plan` sets per-metric.
- **Mixed-format backend parsing (D7).** Decide the per-row parsing for api/worker (pino JSON) vs. postgres (plain text) so no panel silently empties on a JSON miss.
- **Web-vitals aggregation LogQL.** Exact `| logfmt | unwrap value_* | quantile_over_time(...)` (or equivalent) for p75 vitals, with good/needs-improvement/poor thresholds per metric (CLS/LCP/INP/FCP/TTFB have different scales/units).
- **Console-echo dedup placement.** Apply the `!= "console.error:"` exclusion to *every* headline exception-count panel; document it in-JSON (panel description / query comment) so it isn't "simplified" back to a kind filter. Confirm the React-boundary panel needs no dedup.
- **`noValue` text + minified-stack caption.** Wording for each empty-state and the exception-detail text panel.
- **Panel layout / gridPos.** Hand-authored compact JSON matching the existing dashboards' `gridPos` style; api/worker/postgres rows on the backend dashboard.
- **VERSION bump + repin + rebuild + redeploy (FR-67).** `VERSION` 0.3.0→0.4.0; `docker-compose.yml` grafana tag; confirm the build verification still passes and the seven dashboards don't regress. No tag-clobber.
- **Tag-clobber CI guard (D8).** Decide: include the guard task or defer — flag either way.
- **Task numbering.** F004 ended at T107; F005 tasks continue from **T108**. FRs continue from FR-58 (this spec uses FR-59–FR-68); NFRs from NFR-22 (this spec uses NFR-23–NFR-25).

`tasks.md` will decompose into phases mirroring prior features for F005's read-only/visualization scope: (0) freeze queries against live Loki; (1) author `frontend.json` + verify panels against live data; (2) author `backend-logs.json` (incl. postgres mixed-format) + verify; (3) VERSION bump + image rebuild + redeploy + no-regression check; (4) optional tag-clobber CI guard (D8); (5) acceptance walk-through (Scenarios 1–8). No 24h stability observation is needed — this adds no runtime service, only baked dashboard JSON (deploy-and-verify, not soak).
