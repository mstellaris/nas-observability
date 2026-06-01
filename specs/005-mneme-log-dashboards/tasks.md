# Tasks: Mneme Log Dashboards (Frontend RUM + Backend Logs)

**Feature Branch:** `005-mneme-log-dashboards`
**Spec:** [`spec.md`](./spec.md)
**Plan:** [`plan.md`](./plan.md)
**Status:** Ready for implementation

---

## Overview

9 tasks across 6 phases (Phase 0 + Phases 1–5), numbered **T108–T116** (continuing F004's T086–T107 sequence). Tasks marked `[P]` can run in parallel with other `[P]` tasks in the same phase.

**Phase 0 (the keystone — "freeze every query against live Loki") is split by data availability**, because the checks have two different readiness profiles:
- **Can-check-now** (T108, T109) — runs against telemetry *already in Loki*: backend pino/postgres logs flow continuously, and normal browsing already produced web-vitals/events/navigation/browser records. These are immediate queries, no setup.
- **Needs-trigger** (T110) — requires *deliberately triggering* a frontend exception (and a React error-boundary error) to observe the real-exception-plus-`console.error:`-echo pair the dedup depends on. Cannot be checked until an exception is fired.

This is the F003-T075 / F004-Phase-0 discipline: **don't freeze a panel query against an unverified field name.** Phase 0's outputs are the corrected label keys, field names, level encoding, echo prefix, and postgres pattern that Phases 1–2 author against.

**This feature adds NO runtime service** — the only deployed artifact is the Grafana image rebuilt with two baked dashboards (`VERSION` 0.3.0 → 0.4.0). So there is **no 24h stability observation** (deploy-and-verify, not soak — Plan §Phases). FR-68 fences the feature to baked-dashboard-JSON; nothing in the metrics or logs/RUM subsystems changes.

**Total:** 9 tasks (T108–T116).
**Parallelizable:** Phase 0's two can-check-now tasks (T108/T109); the two authoring tasks T111/T112 are sequential-ish only by shared review attention, not by data dependency (both depend on Phase 0).
**T116 (retrospective stub)** executes at close, after T115.

---

## Phase 0: Freeze Queries Against Live Loki (the keystone)

All three tasks are verification-only; their outputs are the frozen label keys / field names / filters that Phases 1–2 author against. Capture every confirmed value in the PR description (the "frozen query reference").

### T108 — Backend freeze: label key, pino numeric level, postgres severity `[P]` `[can-check-now]`

**Files:** (none; outputs recorded in PR, consumed by T112)

**Acceptance:**

**Given** api/worker/postgres logs are already flowing into Loki (continuous — checkable immediately, no trigger needed)
**When** the backend queries are run against live Loki (Explore)
**Then** `service_name` is confirmed as the label key carrying `mneme-api-1` / `mneme-worker-1` / `mneme-postgres-1` (both `container` and `service_name` exist; confirm `service_name` values — Spec D3)
**And** the **pino level encoding is confirmed NUMERIC** — earlier live capture showed `{"level":30,...}`; confirm `30`=info / `40`=warn / `50`=error / `60`=fatal in the current stream (Plan §risk: the silent-empty trap)
**And** **`{service_name=~"mneme-(api|worker)-1"} | json | level>=40` is confirmed to actually return warn/error lines** — i.e. LogQL treats the json-extracted `level` as a *number* for the `>=` comparison (the same "does the extracted field compare as a number" question as the web-vitals `unwrap`; if it compares as a string, the filter is corrected at freeze time)
**And** the `msg` field name (pino message) is confirmed for the top-error-messages aggregation
**And** the **postgres** path is frozen **by observing the actual log line as it lands IN LOKI** (NOT Mneme's `log_line_prefix` server setting — that lives in Mneme's territory and is not visible from this repo; what *is* observable is the postgres line as it arrives in Loki): query `{service_name="mneme-postgres-1"}`, confirm it renders with **no** `| json` (D7 — raw needs no extraction), and **derive the `| pattern "...<severity>..."` template from that observable line shape** — **or** use the `|~ "ERROR|FATAL|WARNING"` keyword fallback, which sidesteps prefix-matching entirely and is the **safe default**. Never `| json` on postgres.

### T109 — Frontend non-exception freeze: web-vitals field, events, browser `[P]` `[can-check-now]`

**Files:** (none; outputs recorded in PR, consumed by T111)

**Acceptance:**

**Given** normal browsing has already produced web-vitals / events / navigation / browser records under `service_name="mneme-frontend"` (checkable now — no exception needed)
**When** the non-exception frontend queries are run against live Loki
**Then** the **web-vitals field ambiguity is resolved**: live data showed BOTH `cls=0.000016` (rounded bare) AND `value_cls=1.62e-05` (full-precision `value_*`) — confirm **which field is canonical** for the `unwrap` (default expectation: the precision-preserving `value_*`, but verify, don't assume)
**And** **`| logfmt | unwrap value_<vital>` is confirmed to return NUMERICS** for `quantile_over_time` (logfmt-extracted fields sometimes need type handling before `unwrap` — same numeric-comparison question as T108's `level>=40`); if not, the type-coercion is added at freeze time
**And** the per-vital field names are confirmed for all five (`value_lcp`/`value_cls`/`value_inp`/`value_fcp`/`value_ttfb` or their bare equivalents)
**And** the `kind=event` session-start value is confirmed — **`event_name` is already the confirmed discriminator** from live data (earlier capture showed `event_name=session_extend` and `event_name=faro.performance.resource`), so the only open question is the exact **start**-event value (likely `event_name=session_start`, sibling to the observed `session_extend`) — confirm that literal
**And** `page_url` (navigation) and `browser_name` (`browser_*` family) field names are confirmed for the navigation/browser panels

### T110 — Frontend exception freeze: echo-dedup + boundary panel `[needs-trigger]`

**Files:** (none; outputs recorded in PR, consumed by T111)

**Acceptance:**

**Given** the echo-dedup (Spec D2) and the React-boundary panel depend on observing a **real exception and its `console.error:` echo** — which requires deliberately triggering an exception (and a boundary error) in Mneme
**When** an exception (uncaught/unhandled-rejection) and a React error-boundary error are triggered, and the resulting Loki streams inspected
**Then** the **echo pair is confirmed**: one triggered error produces TWO `kind=exception` streams — the real one and a `value`-prefixed `console.error:` echo (same kind, different content hash — Spec D2)
**And** **`!= "console.error:"` is confirmed to halve the count** correctly — one triggered error reads as **1**, not 2 (Scenario 2)
**And** the **false-match edge case is checked** (Plan §risk / settled input #2): confirm **no real exception message legitimately contains the substring `console.error:`** (it would be wrongly excluded). If any do, switch the headline panels to the anchored-after-parse form `| logfmt | value !~ "^console.error:"`; otherwise the raw pre-parse `!= "console.error:"` is fine and faster at single-user scale
**And** the **boundary panel filter is confirmed**: `{service_name="mneme-frontend"} | logfmt` cleanly extracts `context_source`, and its value is **exactly `react_boundary`** (unquoted, underscore — exact-match filters are brittle, so verify the literal), and `context_componentStack` is present as a distinct field on boundary errors
**And** the boundary panel's **echo-safety is confirmed by construction** — the `console.error:` echo carries **no** `context_source`, so `context_source="react_boundary"` excludes echoes with no extra dedup needed (A4 exempt from the `!=` filter)
**And** the exception `value` field name (the message, for the top-exceptions table) is confirmed

---

## Phase 1: Author the Frontend Dashboard

### T111 — Author `docker/grafana/dashboards/mneme/frontend.json` + verify against live data

**Files:** `docker/grafana/dashboards/mneme/frontend.json` (NEW)

**Acceptance:**

**Given** T109 + T110 froze the frontend label, field names, echo-dedup, web-vitals field, and boundary filter
**When** the dashboard JSON is hand-authored to the repo model
**Then** it sets `schemaVersion: 39`, `id: null`, `version: 1`, `editable: false`, `refresh: "30s"`, `time: now-6h`, `templating.list: []` (no template vars — Spec D5/FR-64), `uid: "mneme-frontend"`, `title: "Mneme — Frontend"`, `tags: ["mneme","frontend"]`
**And** every panel + target references `{"type":"loki","uid":"loki"}` (UID-keyed — v1.1) and queries `service_name="mneme-frontend"`
**And** it contains the FR-60 panels: total-exceptions stat, exception-rate timeseries, top-exception-messages table, React-boundary panel (surfacing `context_componentStack`), exception-detail logs panel, **five per-vital web-vitals timeseries** (each own axis + standard CWV thresholds: LCP 2.5/4s, CLS 0.1/0.25, INP 200/500ms, FCP 1.8/3s, TTFB 800ms/1.8s), sessions stat+timeseries, navigation-by-page table, browser-breakdown
**And** every headline exception-count panel (total, rate, top-messages, detail) carries the **frozen echo-dedup filter** (`!= "console.error:"` or the T110 anchored fallback) AND a `description` field documenting why it's load-bearing and that it must NOT be replaced by a `kind`/`detected_level` filter (Plan §dedup wording, points to spec.md D2)
**And** the React-boundary panel does **not** carry the `!=` filter (echo-safe by construction — A4)
**And** the error/exception panels set `noValue` text (e.g. "No frontend exceptions in range — this is the healthy state" — FR-65)
**And** the exception-detail area includes a text-panel caption that stacks are minified/unsymbolicated (symbolication deferred — FR-66)
**And** it contains **NO** `client_errors_total` panel (counter removed in Mneme F012 — FR-66)
**And** each panel renders correctly against live frontend telemetry (Scenarios 2–4, 6) — the echo-dedup test (one error → count of 1) explicitly passes
**And** the **rendered LAYOUT is verified, not just render-without-error**: every panel carries explicit `x`/`y`/`w`/`h` (Grafana rows do NOT auto-flow hand-authored JSON), cumulative `y` offsets are correct so panels neither overlap nor gap, and the result matches the intended structure — cross-check `gridPos` against the F003 `mneme/` dashboards as the reference. "Renders" ≠ "laid out as intended."

---

## Phase 2: Author the Backend Logs Dashboard

### T112 — Author `docker/grafana/dashboards/mneme/backend-logs.json` (pinned row layout) + verify

**Files:** `docker/grafana/dashboards/mneme/backend-logs.json` (NEW)

**Acceptance:**

**Given** T108 froze the backend label, pino numeric level, and postgres severity path
**When** the dashboard JSON is hand-authored to the repo model
**Then** it sets the same model fields as T111 (`schemaVersion: 39`, `editable:false`, `templating.list: []`, etc.), `uid: "mneme-backend-logs"`, `title: "Mneme — Backend Logs"`, `tags: ["mneme","backend","logs"]`, all panels `{"type":"loki","uid":"loki"}`
**And** it uses the **pinned four-row layout** (Grafana `row` panels — resolves the panel-overlap flagged in plan review; api/worker/postgres spine per D4/D7):
  - **Row 1 — "Summary (all backend)":** log-volume-by-level timeseries [`w16 h8`] + error+warn-rate stat [`w8 h8`] (both api+worker via `| json | level>=40`); combined live stream [logs, `w24 h8`, `{service_name=~"mneme-(api|worker|postgres)-1"}` — raw, no extraction]; top-error-messages table [`w24 h6`, api+worker `| json | level>=50`]
  - **Row 2 — "API (mneme-api-1)":** api log stream [logs, `w24 h8`, `{service_name="mneme-api-1"}`]
  - **Row 3 — "Worker (mneme-worker-1)":** worker log stream [logs, `w24 h8`, `{service_name="mneme-worker-1"}`]
  - **Row 4 — "Postgres (mneme-postgres-1)" (the format-divergent row):** postgres raw stream [logs, `w16 h8`, `{service_name="mneme-postgres-1"}` — **no `| json`**] + postgres severity count [timeseries/stat, `w8 h8`, `| pattern`/`|~ "ERROR|FATAL|WARNING"` per T108 freeze]
**And** the error+warn stat sets `noValue` text (e.g. "No backend errors/warnings in range — healthy" — FR-65)
**And** **no panel silently shows "no data" for postgres from a `| json` miss** (D7/FR-63 — postgres panels use raw logs / `| pattern` / `|~`, never `| json`)
**And** all three containers' logs are queryable by `service_name` (Scenario 5); api/worker level aggregation and the postgres raw+severity paths both render against live data
**And** the **rendered four-row LAYOUT is verified, not just render-without-error**: every panel (incl. the `row` separators) carries explicit `x`/`y`/`w`/`h`, Row 1's stacked summary panels (`w16`+`w8` at one `y`, then `w24` stream, then `w24` table) have correct cumulative `y` offsets so nothing overlaps or gaps, and the rendered result matches the intended Row 1–4 structure — cross-check `gridPos` against the F003 `mneme/` dashboards. "Renders" ≠ "laid out as intended."

---

## Phase 3: Deploy — VERSION Bump, Rebuild, Redeploy, No-Regression

### T113 — Bump VERSION 0.3.0→0.4.0, repin compose, rebuild, redeploy, verify

**Files:** `VERSION`, `docker-compose.yml`

**Acceptance:**

**Given** T111 + T112 added two baked dashboards under `docker/grafana/dashboards/mneme/` (which triggers the `build-grafana-image` workflow via its `docker/grafana/**` path filter)
**When** the deploy step runs
**Then** `VERSION` is bumped **0.3.0 → 0.4.0** (mandatory — baked content changing without a bump re-pushes a mutable tag; F004 retro fix-chain #4 / tag-clobber — FR-67)
**And** `docker-compose.yml` repins `grafana:` from `v0.3.0` to `v0.4.0`
**And** the `build-grafana-image` workflow builds + pushes `grafana:v0.4.0` + `grafana:sha-<sha>` — and this is a **new** tag, not a re-push of an existing one
**And** the metrics stack is redeployed via Portainer ("redeploy with new image")
**And** **no-regression is confirmed** (Scenario 1 / NFR-24): both new dashboards appear in the Mneme folder with all panels Loki-backed and rendering; the **seven existing F001–F003 dashboards render unchanged**; both `uid: prometheus` and `uid: loki` datasources are healthy

---

## Phase 4: Optional Harden — Tag-Clobber CI Guard (Spec D8)

### T114 — Decide + (optionally) add the tag-clobber CI guard `[optional]`

**Files:** `.github/workflows/build-grafana-image.yml` (MODIFIED — only if included)

**Acceptance:**

**Given** F004 retro carry-forward #1 (a CI guard failing the build if `grafana:v${VERSION}` already exists as a published GHCR tag — machine-enforcing the bump discipline fix-chain #4 violated), and that this is the **second** Grafana-image change since that lesson
**When** the include-or-defer decision is made (Plan §Deploy mechanics — judgment call, flagged either way)
**Then** the decision is **recorded in the PR** (not silently dropped)
**And** **if included:** a step is added to `build-grafana-image.yml` that queries the GHCR tags API for `grafana:v${VERSION}` and **fails the build with a "bump VERSION" message if it already exists** on a content-changing push — verified it passes on a fresh tag (`v0.4.0`) and would have failed on the F004 tag-clobber scenario
**And** **if deferred:** the deferral + its trigger (next Grafana-image change, or standalone hardening) is noted, mirroring how F002/F003 carry-overs are deferred with explicit trigger criteria

---

## Phase 5: DS224+ Acceptance Walk-Through

### T115 — Operator acceptance pass over Spec Scenarios 1–8

**Files:** (none; results recorded in PR / retrospective)

**Acceptance:**

**Given** Grafana `v0.4.0` is deployed with both dashboards
**When** the operator walks Spec Scenarios 1–8
**Then** **Scenario 1** — both dashboards in the Mneme folder, Loki-backed, rendering; seven existing dashboards unregressed
**And** **Scenario 2 (the keystone test)** — one triggered frontend error shows as **1** exception, not 2 (echo-dedup correct)
**And** **Scenario 3** — the React-boundary panel shows boundary errors with `context_componentStack`, echo-safe
**And** **Scenario 4** — all five web-vitals render with their standard CWV thresholds
**And** **Scenario 5** — api/worker/postgres logs all queryable by `service_name`; postgres's plain-text logs surfaced (not dropped by a `| json` miss)
**And** **Scenario 5 (numeric-level end-to-end check)** — the known `POST /api/client-errors` `level:50` hits ("client error reported", 7 in the Phase-0 window) MUST appear in panel 5 (Top Error Messages). If they render, the `| json | level>=50` numeric-level filter is confirmed **in the rendered dashboard**, not just in the Phase-0 API query — this is the built-in acceptance test for the pino-numeric-level trap
**And** **Scenario 6** — error/exception panels show sensible `noValue` text in a quiet period (empty reads as healthy)
**And** **Scenario 7** — no new Loki labels introduced; `templating.list: []`; non-label fields parsed query-time
**And** **Scenario 8** — `VERSION` 0.4.0, compose repinned, image rebuilt + redeployed, no tag-clobber
**And** `diagnose.sh` (if it covers Grafana/datasource health) is the first-line check if any panel misbehaves

---

## Phase 6: Close-out

### T116 — Retrospective stub `[executes at close, after T115]`

**Files:** `specs/005-mneme-log-dashboards/retrospective.md` (NEW)

**Acceptance:**

**Given** F005 is the first Loki-backed dashboard feature and the fifth feature overall
**When** the retrospective is written at close
**Then** it captures: what Phase 0 freezing caught (field-name/encoding corrections vs the draft queries — the value of the keystone phase); whether the echo-dedup false-match check found anything; whether the tag-clobber guard (T114) was included or deferred and why; any deploy-time issues counted on the **same all-issues-vs-blocking-only basis F004's retro settled** (F001=13, F002=4, F003=6, F004=4 — F005 will likely be the lowest yet, being baked-JSON-only, but only reads as a clean trend if counted identically; do NOT shift the metric definition); and whether any finding warrants a memory write (e.g. the pino-numeric-level or web-vitals-field-ambiguity lessons, if they'd recur for future per-app log dashboards)
**And** it follows the F001–F004 retrospective shape (the established close-out convention)

---

## Cross-cutting notes

- **No spec/plan amendment** — F005 is a compliance-check feature under v1.2 Architecture B + v1.3 coverage (Plan §Constitution Check). No constitution change.
- **FR/NFR coverage:** FR-59 (T111/T112 model + tier split), FR-60 (T111 panels), FR-61 (T110/T111 echo-dedup), FR-62 (T112 three containers by `service_name`), FR-63 (T112 postgres mixed-format), FR-64 (T111/T112 no labels/no vars), FR-65 (T111/T112 noValue), FR-66 (T111 no client_errors_total / minified caption), FR-67 (T113 deploy), FR-68 (all — no runtime change); NFR-23 (T115 query latency), NFR-24 (T113 no-regression), NFR-25 (T111/T112 legible empty state).
- **The single highest-risk detail is the echo-dedup** (T110 → T111): get it wrong and every error count silently doubles. It is verified live (T110), documented in-JSON against simplification (T111), and falsifiably tested (T115/Scenario 2).
