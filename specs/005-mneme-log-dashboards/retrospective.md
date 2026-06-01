# Retrospective: Mneme Log Dashboards (Frontend RUM + Backend Logs)

**Feature Branch:** `005-mneme-log-dashboards`
**Spec:** [`spec.md`](./spec.md) · **Plan:** [`plan.md`](./plan.md) · **Tasks:** [`tasks.md`](./tasks.md) · **Freeze:** [`phase-0-frozen-queries.md`](./phase-0-frozen-queries.md)
**Status:** **Closed** — PR #10 merged to `main` (2026-06-01), Grafana `v0.4.0` built + redeployed, T115 acceptance passed (all dashboards green, existing seven unregressed).
**Retrospective written:** 2026-06-01

---

## Outcome

Feature 005 is the **first Loki-backed dashboard feature** — two curated per-application dashboards (`Mneme — Frontend`, `Mneme — Backend Logs`), turning F004's Explore-only logs/RUM access into standing panels. It is the follow-up F004 explicitly deferred ("curated logs/RUM dashboards can follow once query patterns settle").

It was the **cleanest feature of the five by every measure**: a single focused PR, **zero deploy-time issues**, no runtime service, no DSM friction, no constitutional change. By the consistent all-in-flight-deploy-issue count used since F001 — **F001 = 13, F002 = 4, F003 = 6, F004 = 4, F005 = 0** — it lands below the F002–F004 band for the first time. The reason is not that F005 had no would-be-bugs: it had **five** (three wrong field/encoding assumptions + two wrong panel-semantics) — but **all five were caught before bake**, at Phase-0-freeze or review time, never reaching deploy. That is the methodology working as designed: the issues moved *left*, from deploy-time to design-time. See *Meta-observation*.

**Stack state post-F005:** unchanged container topology (8 containers, two stacks). The only deployed artifact is the **Grafana image `v0.3.0 → v0.4.0`** with two added baked dashboards. Metrics 600M / logs-RUM 500M caps untouched; both datasources healthy; the seven F001–F004 dashboards render unchanged (NFR-24).

---

## What shipped

**Two Loki-backed dashboards under `docker/grafana/dashboards/mneme/` (Architecture B):**
- **`frontend.json`** (`Mneme — Frontend`, `service_name="mneme-frontend"`) — 3 rows: Exceptions & Errors (total/rate stats + top-messages table, all echo-deduped; React error-boundary panel with `context_componentStack`; exception detail with a minified-stack caption); Web Vitals p75 (five per-vital timeseries on the full-precision `value_*` fields, official CWV thresholds in ms + a thresholds card); Sessions & Navigation (session-start stat/timeseries, navigation-by-page, browsers-by-session donut).
- **`backend-logs.json`** (`Mneme — Backend Logs`, `service_name=~"mneme-(api|worker|postgres)-1"`) — pinned 4-row layout: Summary (volume-by-level, error+warn stat, combined raw stream, top-error table), then API / Worker / Postgres rows. api+worker via pino JSON with numeric `level>=40`/`>=50`; postgres plain-text severity via the anchored `\] (ERROR|FATAL|PANIC|WARNING):` regex — never `| json`.

**Deploy:**
- `VERSION` 0.3.0 → 0.4.0, `docker-compose.yml` grafana repin (tag-clobber discipline — F004 fix-chain #4 honored; clean new tag, no clobber).
- **No** runtime service / datasource / port / backend / Loki / Alloy change (FR-68).

**Process artifact — `phase-0-frozen-queries.md`:** every LogQL query verified against live Loki before authoring. This is the durable record of the freeze and the reference for the next per-app log dashboard.

---

## Deploy notes — the empty fix-chain

**Zero deploy-time issues.** Merge → `build-grafana-image` pushed `v0.4.0` green → Portainer redeploy → both dashboards present, panels rendering, seven existing unregressed. No fix-chain, no benign-behavior surprises, no git-process slips (the branch-freeze discipline from F004 was followed: PR #10 frozen on open, this retro authored on a *fresh* `005-retrospective` branch from `main`).

This is the first feature with an empty fix-chain. It is a baked-JSON-only change — no DSM bind mount, no UID, no socket, no process-creates-subdirs surface — so the *deploy* surface that produced F001–F004's issues simply isn't present here. The risk in F005 was never deploy mechanics; it was **query correctness**, and that risk was retired before bake (next section).

---

## What went well

- **Phase 0 freeze was the whole feature, and it paid.** Running every draft query against live Loki before authoring caught two corrections that would otherwise have shipped wrong panels silently:
  - **Web-vitals fields:** both rounded-bare (`cls`, `lcp`, …) and full-precision (`value_cls`, `value_lcp`, …) forms exist; `value_*` is canonical. And critically **TTFB = `value_ttfb`**, *not* `value_time_to_first_byte` (the TTFB sub-attribution inside an LCP measurement). Using the latter would have rendered a real-looking-but-wrong TTFB panel — the "verify *which* field among similar names, not just *whether* it exists" trap.
  - **Echo dedup mechanism:** the orientation proposed a `kind` filter; the live data showed the console echo is *itself* `kind=exception` (different content hash), so a kind filter would double-count and hash-dedup would fail. The deterministic separator is the `console.error:` value-prefix, verified at 0 false-matches over 7 days.
- **The pino-numeric-level catch** (surfaced during planning, confirmed in Phase 0): pino emits `{"level":50}`, so the error filter is `level>=40` (numeric), not `level="error"` — a classic silent-empty trap, and `| json | level>=40` was confirmed to compare *as a number* against live data.
- **The review checkpoint before bake caught two more** (panel-semantics, not field names): Browser Breakdown counted *every* beacon (resource-timing-dominated, meaningless proportions) → fixed to one-per-session; Navigation-by-page assumed a `faro.performance.navigation` event that had to be confirmed live (it exists) and used *alone* to avoid double-counting the landing page.
- **The orphaned-endpoint finding doubled as a test fixture.** The `/api/client-errors` `level:50` hits (see below) gave T115 a real, known-good fixture for the numeric-level filter end-to-end — the bug being surfaced *is* the acceptance evidence.
- **Compliance-not-amendment held.** The orientation call (v1.2 Architecture B + v1.3 coverage already cover this) was correct; no constitution churn.

## What went poorly

- **Genuinely little.** The closest thing to a miss is that the **plan's draft queries embedded three wrong assumptions** (web-vitals `value_*`-vs-bare unresolved, TTFB field, pino level encoding). That's *by design* — the plan marked them `⚠ FREEZE` and Phase 0 is the gate — but it's worth stating plainly: **authoring straight from the plan draft, skipping the freeze, would have shipped ~3 wrong panels.** The freeze is not optional polish; it is the load-bearing step for any log-dashboard feature. (This is the memory below.)
- **No soak, by design** — correct for baked-JSON-only, but it means "looks okay" at T115 is the acceptance bar; if a low-traffic panel is subtly wrong it'd surface only with more data. Acceptable at single-user scale; noted for honesty.

---

## Carry-forward follow-ups

1. **Tag-clobber CI guard — deferred TWICE now (F004 retro → F005), with a concrete trigger this time.** Kept out of PR #10 deliberately (orthogonal CI-mechanism change; muddies the dashboard review surface; a standalone PR lets the guard be tested on its own — fails on a duplicate tag, passes on a fresh one). **Trigger: land it as a standalone PR _before the next Grafana-image change_**, so the guard is in place before the next clobber opportunity — not open-ended backlog. (Sketch unchanged from F004 follow-up #1: query the GHCR tags API for `grafana:v${VERSION}`; fail a content-changing push if it already exists.)
2. **`mneme-caddy-1` access-log dashboard/row — additive future work.** Caddy (Mneme's frontend reverse proxy) also ships to Loki, but its access-log shape is a different design (status/latency/path per request) than app backends; D4 kept it out deliberately. Candidate for a future row on the backend dashboard or its own `mneme/caddy.json`. Captured so the option isn't lost.

---

## Findings surfaced (cross-repo — Mneme-side)

**`POST /api/client-errors` still errors at `level:50` post-F012.** Phase 0 / T115 surfaced 7 backend error logs ("client error reported") on the `/api/client-errors` endpoint. Mneme's **F012 removed the `client_errors_total` *counter*** (frontend errors now go to Loki via Faro), but the **endpoint itself appears to still exist and error**. Open question for the Mneme work stream: **should `/api/client-errors` have been torn down with F011?** This is a *transient one-time cleanup item* — it resolves when Mneme removes/fixes the endpoint — so it is recorded here and to be **raised in Mneme chat**, **not** written as a memory (a memory about it would go stale the moment it's fixed). The dashboard surfacing it on day zero is the backend-logs dashboard doing exactly its job; the fix (if any) is Mneme-side, and the logs are left unfiltered (real backend-error signal).

---

## Meta-observation: the discipline moved issues left

F005 is the smallest feature of the five and the first with an **empty deploy fix-chain** (F001 = 13 → F002 = 4 → F003 = 6 → F004 = 4 → **F005 = 0**, all counted on the same all-in-flight-deploy-issues basis). But the headline isn't "F005 was easy" — it's *where its issues went*.

F005 had **five would-be-bugs** (three wrong field/encoding assumptions, two wrong panel-semantics). In an earlier-discipline world several would have shipped: a TTFB panel reading the wrong sub-field, error counts silently doubled by the console echo, empty error panels from `level="error"` on numeric data, a meaningless browser donut. **None reached deploy.** Three died at the Phase-0 freeze (field/encoding), two at the pre-bake review (panel-semantics). The deploy was clean *because* the correctness work happened before the bake, not because there was no correctness work.

This is the same compounding the F004 retro named, applied to a new risk class. F001–F004 moved *platform/DSM* surprises from deploy-time to design-time via the memory corpus and Phase-0 capability gates. F005 moved *query-correctness* surprises from deploy-time to design-time via the live-Loki freeze. The pattern generalizes: **the cheapest place to be wrong is against live data before you author, not in a baked panel after you deploy.** That is the memory this feature earns (below) — it will recur verbatim for every future per-app log dashboard (Pinchflat, Immich, …).

---

## Memory system state at close

- **New memory written:** `project_freeze_log_dashboard_queries_live.md` — for any log/RUM dashboard (this repo's Loki-backed dashboards), freeze every LogQL query against the *running* Loki before authoring; field names among similar candidates and encodings are not guessable. Generalized from F005's `value_ttfb`-vs-`value_time_to_first_byte`, console-echo-is-`kind=exception`, and pino-numeric-level catches. Recurs for every future per-app log dashboard. `MEMORY.md` index updated.
- **Not a memory (deliberate):** the `/api/client-errors` finding (transient cross-repo cleanup — would go stale; lives in this retro + Mneme chat). The web-vitals/pino *specifics* (Mneme-particular; won't recur identically) — only the *generalized freeze discipline* is durable enough to store.
- `project_overview.md` already reflects the metrics+logs+RUM platform; F005 adds no platform fact (no new service/budget/retention), so no overview update needed — the new dashboards are derivable from the repo.
- No stale/contradictory memories surfaced; index regenerated.
