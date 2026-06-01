# Phase 0 — Frozen Query Reference (verified against live Loki)

**Status:** Complete — all of T108/T109/T110 verified against the running Loki at `http://192.168.0.8:3100` (reachable on the LAN; host-networked) over the last 7 days of data, 2026-06-01.
**Purpose:** the gate output that T111 (frontend.json) and T112 (backend-logs.json) author against. Every field name, label key, level encoding, and filter below is **observed**, not assumed.

> Phase 0 was runnable end-to-end without triggering anything: the F012 verification exceptions (real + `console.error:` echo) are still within Loki's 7-day retention, so even the "needs-trigger" T110 checks were frozen against real historical data.

---

## Labels (confirmed)

- Label keys present: **`service_name`**, `container`, `compose_service`, `job`.
- `service_name` values include: `mneme-frontend`, `mneme-api-1`, `mneme-worker-1`, `mneme-postgres-1` — **and also `mneme-caddy-1`** (see Observations).
- **Decision held (Spec D3):** both dashboards key on `service_name`. Confirmed it carries the expected values for all four target streams.

---

## T108 — Backend (mneme-api-1 / mneme-worker-1 / mneme-postgres-1)

### Pino level — NUMERIC (confirmed)
- api/worker emit pino JSON: `{"level":30,"time":...,"pid":1,"hostname":"DS224plus","req":{...},"msg":"request completed"}`.
- Level encoding is **numeric**: `30`=info, `40`=warn, `50`=error, `60`=fatal.
- **`| json | level>=40` compares as a NUMBER** — verified it returns real `level:50` error lines (e.g. a `DatabaseError "terminating connection due to administrator"`). The numeric-comparison trap is cleared.
- Message field is **`msg`** (e.g. `msg="request completed"`) — use for top-error-messages grouping.

**Frozen backend queries:**
| Purpose | LogQL |
|---|---|
| Volume by level (api+worker) | `sum by (level) (count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json [$__auto]))` |
| Error+warn rate | `sum(count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json \| level>=40 [$__range]))` |
| Top error messages | `topk(10, sum by (msg) (count_over_time({service_name=~"mneme-(api\|worker)-1"} \| json \| level>=50 [$__range])))` |
| Errors-only (app) | `{service_name=~"mneme-(api\|worker)-1"} \| json \| level>=40` |
| Per-container stream | `{service_name="mneme-api-1"}` / `{service_name="mneme-worker-1"}` |

> Note for the volume-by-level panel: `level` arrives as a number (30/40/50/60). Add Grafana **value-mapping field overrides** (30→info, 40→warn, 50→error, 60→fatal) so the legend reads in words.

### Postgres — plain text, NO `| json` (confirmed)
- Observed line shape **in Loki** (not the server's `log_line_prefix`, which isn't visible from this repo):
  ```
  2026-06-01 00:15:23.146 UTC [27] LOG:  checkpoint complete: ...
  2026-06-01 00:10:02.558 UTC [1] LOG:  database system is ready to accept connections
  ```
  i.e. `<date> <time> UTC [<pid>] <SEVERITY>:  <message>` (two spaces after the severity colon).
- **Frozen postgres path (D7):**
  - Raw stream (no extraction): `{service_name="mneme-postgres-1"}` — renders fine, this is the live-tail panel.
  - Severity match — **CHOSEN: position-anchored regex** `|~ \`\] (ERROR|FATAL|PANIC|WARNING):\`` (anchors on the `[pid]` bracket + trailing colon, so it can't match these words inside a message body). Verified live: matches real non-`LOG` severities, parses clean. Includes **PANIC** (a naive `ERROR|FATAL` would miss panics). Chosen over the looser `|~ "(ERROR|FATAL|PANIC|WARNING)"` deliberately — strictly more correct at no real cost.
  - Severity count: `sum(count_over_time({service_name="mneme-postgres-1"} |~ \`\] (ERROR|FATAL|PANIC|WARNING):\` [$__range]))`.
  - **Never `| json` on postgres.**

---

## T109 — Frontend non-exception (web-vitals, events, browser)

### Web-vitals — use the full-precision `value_*` fields (the ambiguity is REAL and resolved)
- Live data carries **both** forms for every vital (exactly the flagged ambiguity): rounded bare (`cls`, `lcp`, `inp`, `fcp`, `ttfb`) **and** full-precision `value_*` (`value_cls`, `value_lcp`, `value_inp`, `value_fcp`, `value_ttfb`).
- **Canonical for `unwrap` = the `value_*` field** (full precision). Confirmed `| logfmt | unwrap value_lcp | quantile_over_time(0.75, …)` returns a numeric matrix (sample `96`).
- Standalone TTFB metric is **`value_ttfb`** — distinct from `value_time_to_first_byte` (that one is the TTFB sub-attribution *inside* an LCP measurement; do NOT use it for the TTFB panel).
- Frontend body is **logfmt** (`| logfmt`), not JSON.

**Frozen web-vitals queries (one panel per vital, own axis + CWV thresholds):**
| Vital | LogQL (p75) | Grafana unit | Thresholds (good / poor) |
|---|---|---|---|
| LCP | `quantile_over_time(0.75, {service_name="mneme-frontend"} \| logfmt \| value_lcp!="" \| unwrap value_lcp [$__auto])` | `ms` | green<2500, yellow≥2500, red≥4000 |
| FCP | …`unwrap value_fcp`… | `ms` | green<1800, red≥3000 |
| INP | …`unwrap value_inp`… | `ms` | green<200, red≥500 |
| TTFB | …`unwrap value_ttfb`… | `ms` | green<800, red≥1800 |
| CLS | …`unwrap value_cls`… | `short` (unitless) | green<0.1, red≥0.25 |

> Values are in **milliseconds** for LCP/FCP/INP/TTFB (so thresholds are in ms, e.g. LCP 2500/4000), and **unitless** for CLS (0.1/0.25). Confirmed numeric via the unwrap test.

### Events / sessions / navigation / browser
- Body is logfmt; `kind=event` with **`event_name`** discriminator. Observed values: **`session_start`**, `session_extend`, `faro.performance.navigation`, `faro.performance.resource`.
- `session_id`, `page_url`, and the `browser_*` family all present: `browser_name`, `browser_version`, `browser_os`, `browser_mobile`, `browser_language`, `browser_userAgent`, `browser_viewportWidth/Height`.

**Frozen event queries:**
| Purpose | LogQL |
|---|---|
| Sessions started (range) | `sum(count_over_time({service_name="mneme-frontend"} \| logfmt \| event_name="session_start" [$__range]))` |
| Navigation by page | `topk(10, sum by (page_url) (count_over_time({service_name="mneme-frontend"} \| logfmt \| event_name=~"faro.performance.navigation\|session_start" [$__range])))` |
| Browser breakdown | `sum by (browser_name) (count_over_time({service_name="mneme-frontend"} \| logfmt [$__range]))` |

---

## T110 — Frontend exceptions + echo-dedup (frozen against real historical data)

### The echo pair (Spec D2 — confirmed exactly)
- One triggered error yields **two** `kind=exception` streams:
  - **Real:** `value="F012 faro-verification: react_boundary trigger"` (no `console.error:` anywhere)
  - **Echo:** `value="console.error: F012 faro-verification: react_boundary trigger"` (prefix in `value` AND in `stacktrace`)
- Same `kind=exception`, different content → a `kind` filter double-counts and hash-dedup fails (as predicted).

### Dedup filter — `!= "console.error:"` (confirmed zero false-matches)
- **Verified: 0 real (non-echo) exception lines contain the substring `console.error:`** across the 7-day window. So the raw line-filter is safe and fast.
- **Frozen headline-count filter:** `{service_name="mneme-frontend"} |= "kind=exception" != "console.error:"`
- **Robust alternative (kept on record):** `… | logfmt | value !~ "^console.error:"` — anchors on the parsed `value` only. The raw `!=` also matches the echo's stacktrace occurrence (which is fine — it's still an echo), but if a future *real* error's stacktrace ever legitimately contains `console.error:`, switch to the anchored form. Not needed for current data.

### Exception types observed
- **Boundary** (`context_source=react_boundary`, has `context_componentStack`): the F012 react_boundary triggers.
- **Uncaught / unhandled-rejection** (NO `context_source`, NO componentStack): `post-teardown: uncaught …`, `faro-verify2: rejection …`, `faro-verify2: uncaught …`.
- So the "all exceptions" count (`!= "console.error:"`) captures all real errors; the boundary panel isolates only boundary ones.

### Boundary panel (Spec A4 — confirmed echo-safe by construction)
- `context_source` distinct values on exceptions: **exactly `react_boundary`** (unquoted, underscore). Exact-match `context_source="react_boundary"` is correct.
- `context_componentStack` present as a distinct field on boundary errors.
- **Echo carries NO `context_source`** → the boundary filter excludes echoes with no extra `!=` needed (A4 exempt from the dedup filter).
- **Frozen boundary query:** `{service_name="mneme-frontend"} | logfmt | context_source="react_boundary"` (surface `context_componentStack`).

### Minified stacks (confirmed)
- Stacks reference bundled assets, e.g. `at Il (http://192.168.0.8:8080/assets/index-jQk4oDYt.js:29:53618)` — unsymbolicated. The exception-detail panel gets the minified-stack caption (FR-66).

**Frozen exception queries:**
| Purpose | LogQL |
|---|---|
| Total exceptions (range) | `sum(count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" [$__range]))` |
| Exception rate | `sum(count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" [$__auto]))` |
| Top exception messages | `topk(10, sum by (value) (count_over_time({service_name="mneme-frontend"} \|= "kind=exception" != "console.error:" \| logfmt [$__range])))` |
| Exception detail (logs) | `{service_name="mneme-frontend"} \|= "kind=exception" != "console.error:"` |
| React boundary errors | `{service_name="mneme-frontend"} \| logfmt \| context_source="react_boundary"` |

---

## Observations surfaced during freezing (flag for review — not blocking)

1. **`mneme-caddy-1` also ships logs to Loki.** It's Mneme's frontend reverse proxy (the access-log tier). Spec D4 scoped the backend dashboard to api/worker/postgres explicitly — so caddy is **out of current scope**. Flagging in case you want a 4th backend row (access logs) — otherwise it stays out, as specced.
2. **Backend still logs `POST /api/client-errors` at `level:50`.** Two of the sampled error lines are this endpoint. Mneme F012 removed the `client_errors_total` *metric counter*, but the backend endpoint appears to still exist and error. Not a dashboard concern (we build no client_errors panel — FR-66), but the backend error panels *will* show these. Noted in case it's unexpected.
3. **A `DatabaseError "terminating connection due to administrator"`** appears in the api error stream (likely a past restart) — real error data the error panels will surface. Healthy as a demonstration that the panels work.
4. **`__faro_boundary_test` field** appears on some frontend records — an F012 test artifact, harmless, parsed-only (never a label).

---

## Net corrections vs the plan's draft queries

| Plan draft assumed | Frozen reality |
|---|---|
| Web-vitals field uncertain (`value_*` vs bare) | **`value_*` is canonical** (full precision); bare is rounded. Confirmed unwrap returns numerics. TTFB = `value_ttfb`, NOT `value_time_to_first_byte`. |
| Pino level encoding TBD | **Numeric** (30/40/50/60); `level>=40` compares as a number. Add value-mappings for the legend. |
| Postgres `\| pattern` from `log_line_prefix` | Derived from the **observed Loki line**; `|~ "(ERROR\|FATAL\|PANIC\|WARNING)"` is the safe default, `\| pattern` optional. |
| Echo dedup needs a trigger | Frozen against **existing** F012 exceptions in retention; 0 false-matches on `!= "console.error:"`. |
| `context_source` value to verify | Exactly **`react_boundary`**; echo has none (boundary panel echo-safe). |
| session_start discriminator open | **`event_name=session_start`** confirmed (sibling to observed `session_extend`). |
