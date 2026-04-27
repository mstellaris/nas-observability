# Parking state

Snapshot of the project state when a working session is paused. Append a new top-level section per pause event; the most recent entry is the current state.

---

## 2026-04-26 — Post-F003 close-out

### Date paused
2026-04-26.

### Last shipped feature
**F003 — Mneme Application Scraping & Dashboards.** Code complete + 24h observation passed; retrospective finalized; doc-debt polish (carry-over Item 1 + Item 2 from the retro) merged via PR #2.

### Constitution version
**v1.2.0.** Initially ratified 2026-04-23 at v1.0.0. Amended 2026-04-24 → v1.1.0 (DSM platform constraints from F001 retrospective: DSM UID restriction, baked-vs-state path separation, datasource UID determinism). Amended 2026-04-26 → v1.2.0 (Architecture B for per-application dashboards: consumer dashboards live in this repo under `docker/grafana/dashboards/<consumer-slug>/`, baked at image-build time, replacing the original cross-repo sync model). No pending amendments staged or half-drafted; full amendment history in `.specify/memory/constitution.md`.

### Memory system
**9 entries, stable, internally consistent** as of this parking close-out. See "Memory system audit" subsection below for what changed during the pre-close audit.

### Stack state on DS224+
- **6 services running**: prometheus, grafana, cadvisor, node-exporter, snmp-exporter, postgres-exporter.
- **7 Prometheus scrape jobs UP**: prometheus, node_exporter, cadvisor, synology, mneme-api, mneme-worker, mneme-postgres.
- **7 Grafana dashboards across 3 folders**: stack/ (stack-health), synology/ (nas-overview, storage-volumes, network-temperature), mneme/ (api, worker, database). All rendering live data; Mneme worker's two histogram panels show their `noValue` strings as designed.
- **600 MB `mem_limit` cap held exactly** (cAdvisor 60M, node_exporter 30M, snmp_exporter 40M, postgres_exporter 50M, Grafana 140M, Prometheus 280M = 600M). Observed totals well below cap throughout the 24h observation window.
- **24h stability observation passed**: zero scrape-duration drift across all three Mneme jobs (mneme-api ~5–6 ms, mneme-worker ~4 ms, mneme-postgres ~28–30 ms, all flat). Postgres baseline trended slightly *down* (cache warming), opposite of a leak signature.

### Open carry-overs from F003 retrospective
Three deferrals with concrete revisit criteria captured in `specs/003-mneme-app-scraping/retrospective.md` §Carry-over to Feature 004:

1. **Heatmap `noValue` limitation** on the Mneme Worker dashboard's Parser Confidence panel — Grafana 11.4 heatmaps don't honor the `fieldConfig.defaults.noValue` config the way time-series/stat/table panels do. Revisits when Mneme Ingestion (the worker code that observes `parser_confidence`) ships.
2. **Multi-arch Grafana image** (amd64 + arm64). Revisits when native arm64 GHA runners reach general availability — currently in limited beta; QEMU-emulation tax (~40s → 2–3 min CI) remains the blocker.
3. **Walkgen replacement of community `snmp.yml.template`**. Revisits per F002's four trigger criteria: DSM major upgrade, a panel needing an OID the community config doesn't expose, scrape-duration drift, or six-month routine maintenance.

### F003 doc-debt polish — shipped
PR #2 (`4fb08e2` content commit, merged as `4ecadab`) closed both Item 1 (SSH-tunnel workflow removal — operator-facing references in `docs/deploy.md`, `specs/003-.../plan.md` §Authoring workflow + §Implementation Phases #6, and `tasks.md` T076) and Item 2 (`<(...)` process-substitution sweep — confirmed clean across `docs/`; F002 `tasks.md:373` left as historical record per the "operator-facing flows" qualifier). Commit message documents both anti-patterns so future doc authors don't reintroduce them.

### Current decision
**F004 parked indefinitely.** No identified next consumer.

Mneme F011 pivoted to external APM (GlitchTip or Bugsink, decision pending in a parallel Mneme session) for application-level error tracking. That APM will likely become a nas-observability consumer in a future F004+ feature once deployed and stable on the NAS.

### Resume criteria
Resume the session when **a concrete application is identified for integration**. Either:
- The chosen APM (GlitchTip or Bugsink, whichever Mneme picks) once deployed and operational on the DS224+, OR
- Another self-hosted app on the NAS that exposes `/metrics` and warrants scraping + dashboarding.

Until one of those fires, F004 spec authoring is on hold. The Architecture B template established by F003 (per-app subfolder, scrape job with appropriate `honor_labels`, dashboards authored against deployed Grafana, integration contract owned in the consumer repo) is ready to receive the next consumer with minimal additional design work.

### Operational state on the NAS — unattended
The deployed stack continues running unattended during the parking period. Per the constitution, **routine maintenance bumps** (Prometheus, Grafana, exporter version updates; security patches) **can land via small PRs outside the spec-kit flow** as long as they satisfy the existing PR compliance checklist (pinned image, `mem_limit`, total ≤ 600 MB, port table, bind mount documentation).

**Anomalies that should resume the session immediately, not wait for F004:**
- Memory creep — observed totals approaching the 600 MB cap.
- Sustained scrape failures on any of the 7 Prometheus jobs.
- Dashboard regressions after a Grafana version bump.
- Any post-bump deploy that requires a Phase 7-equivalent fix-chain longer than 1–2 commits.
- DSM 7.x major upgrade that breaks any of the v1.1/v1.2 platform constraints (UID restriction, baked-vs-state, datasource UID, host networking).

`scripts/diagnose.sh` is the first-line tool for any of those; the `Build Grafana image` workflow's `Verify honor_labels count` step + the PR compliance checklist guard the pre-merge surface.

### Memory system audit (during parking close)
Pre-audit: 10 entries. Two adjustments made:

1. **Deleted** `reference_mneme_dashboards.md`. The memory described Architecture A (Mneme dashboards live in `/Users/stellar/Code/mneme/ops/dashboards/`, pulled into the Grafana image at build time via cross-repo CI sync). This was reversed by Constitution v1.2's Architecture B amendment on 2026-04-26 — dashboards now live in this repo at `docker/grafana/dashboards/mneme/`. Historical context is captured in three other places (constitution v1.2 amendment history, F003 retrospective, Mneme F008's amended spec); a fourth surface was noise. The current authoritative location is derivable from `ls docker/grafana/dashboards/mneme/`.
2. **Updated** `project_overview.md`. Bumped the constitution-version note from "ratified 2026-04-23 at v1.0.0" (which read as "v1.0.0 is current" on cold start) to "Constitution at v1.2.0 — initially ratified 2026-04-23 at v1.0.0; amended 2026-04-24 (v1.1.0, DSM platform constraints from F001 retrospective); amended 2026-04-26 (v1.2.0, Architecture B for per-application dashboards). See `.specify/memory/constitution.md` for current state." Reasoning: cold-start sessions read memories before the constitution; a stale version reference there is the first stale impression.

Post-audit: **9 entries**, all current, no internal contradictions. `MEMORY.md` index regenerated to match.

### State at close
- `git status` clean, working tree empty.
- `main` exactly in sync with `origin/main` (no ahead/behind markers).
- No stranded feature branches (local or remote).
- Constitution at v1.2.0, no half-drafted amendments.
- 9 persistent memories, all internally consistent.
