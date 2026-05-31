# Retrospective: Logs & RUM Subsystem (Loki + Alloy + Faro receiver)

**Feature Branch:** `004-logs-rum`
**Spec:** [`spec.md`](./spec.md) · **Plan:** [`plan.md`](./plan.md) · **Tasks:** [`tasks.md`](./tasks.md)
**Status:** **In observation (T106)** — code complete, all deploy-acceptance scenarios passed (Scenarios 1–10 + T101 beacon), 24-hour stability window pending
**Retrospective written:** 2026-05-31 (scaffold post-T103); T106 outcomes + final close filled in once the window closes

---

## Outcome

Feature 004 is the first feature under **Constitution v1.3.0** — the largest scope expansion of the project to date (metrics-only → metrics + logs + RUM, a category expansion requiring a constitutional amendment, a new compose stack, and a cross-repo contract). Despite that, it was the **smoothest deploy of the four**: a single stack-blocking fix during bring-up (Alloy's storage-mount parent ownership), with the remaining corrections being tooling-robustness, version hygiene, and one self-inflicted git-process slip — none of them functional-blocking. See *The Phase 9 deploy fix-chain* and *Meta-observation* below.

**Stack state post-F004:** **8 containers across two Portainer stacks** —
- **Metrics stack** (`docker-compose.yml`, 6): prometheus, grafana (now **v0.3.0** with the baked Loki datasource), cadvisor, node-exporter, snmp-exporter, postgres-exporter. Held at the **600 MB** cap exactly (unchanged).
- **Logs/RUM stack** (`docker-compose.logs.yml`, 2): loki (200M), alloy (250M) = **450 MB**, within the new **≤ 500 MB** logs/RUM cap.

Both Grafana datasources healthy (`uid: prometheus` + `uid: loki`); F001–F003 dashboards render unchanged after the v0.3.0 rebuild (NFR-22). Both pillars verified live on real traffic: **backend logs** (Alloy → Loki, canonical `container` label, Docker-socket discovery) and **RUM** (Faro receiver — API key, two-origin CORS, trace-drop, signal landing, all confirmed by the T101 synthetic beacon). The cross-repo **Faro contract** was published into Mneme's `docs/observability.md` (PR #3, merged) — **Mneme F012 is unparked.**

---

## What shipped

**Logs/RUM subsystem (new `docker-compose.logs.yml` — separate stack, Spec D2):**
- **Loki** `grafana/loki:3.3.2` — single-binary, filesystem store, TSDB shipper, schema v13, **7-day** retention (`retention_period: 168h` + `compactor.retention_enabled: true` — the line that makes deletion fire). Ports 3100 (HTTP) / 3101 (gRPC, remapped off upstream 9095 into the `3100–3199` band). Runs `1026:100`; state at `/volume1/docker/observability/loki/data`.
- **Alloy** `grafana/alloy:v1.5.1` — three pipelines: `loki.source.docker` (API-based container-log discovery via the Docker socket), host-log file source, and `faro.receiver` (frontend RUM). Runs `1026:100` + `group_add: ["0"]` for socket read; UI remapped 12345→3110 via `--server.http.listen-addr`. State at `/volume1/docker/observability/alloy/data` (mounted as `/var/lib/alloy`).
- **Faro receiver** on host interfaces `0.0.0.0:3111` (HTTP, no TLS, no proxy — Spec D5/T086): native `api_key` + two-origin `cors_allowed_origins` via `sys.env`; `output { logs = [...]; traces = [] }` (traces dropped in code — the v1.3 APM-deferral seam).

**Metrics-side change (the only one):**
- Grafana image **v0.2.1 → v0.3.0** with a baked Loki datasource (`uid: loki`, `localhost:3100`). `VERSION` bumped; `docker-compose.yml` repinned.

**NAS-side wiring + ops:**
- `scripts/init-nas-paths.sh` — creates + `chown`s the loki/alloy state dirs, curls both configs to absolute host paths (Portainer relative-mount constraint).
- `scripts/diagnose.sh` — registers loki + alloy, ports 3100/3101/3110/3111, the new bind paths, a Loki disk-watch readout; plus robustness fixes (per-service `docker logs` `timeout`, port check `ss`→`netstat`).
- `docs/logs-setup.md` — NAS runbook: paths/ACL recovery, API-key gen, the two CORS origins (no-space-after-comma warning), the deliberate HTTP/host-interface/key-sole-gate posture, the disk-watch (no auto byte-cap), the retention-verification short-test, and a troubleshooting section (timestamp-too-old on fresh deploy; transient Alloy errors on metrics-stack redeploy; socket/CORS/401).
- `docs/ports.md` 3100/3101/3110/3111 claimed; `.env.example` Faro vars.

**Constitutional amendment:**
- v1.2.0 → **v1.3.0**: broadened to metrics + logs + RUM; Principle IV split into two subsystem budgets (metrics ≤ 600M / 30d, logs/RUM ≤ 500M / 7d); `3100–3199` port range; APM/Tempo still deferred with trace-dropping enforced in code.

**Cross-repo contract (the payoff):**
- Faro receiver contract published into Mneme's `docs/observability.md` (mneme PR #3, merged) — endpoints, `x-api-key`, two CORS origins, accepted/dropped signals. Plus corrected Mneme's now-stale "log aggregation out of scope" line (F004 ships its logs to Loki, no Mneme change) and added an F012 forward-compat entry. **This unparks Mneme F012.**

---

## The Phase 9 deploy fix-chain

**One stack-blocking fix**, plus tooling/hygiene corrections and one self-inflicted git slip. Trend: F001 = 13, F002 = 4, F003 = 6, **F004 = 1 blocking** (the rest non-functional). See *Meta-observation*.

1. **(Blocking) Alloy crash-loop — storage-mount parent ownership.** Alloy died on `failed to create the remotecfg service: mkdir /var/lib/alloy/data: permission denied`. The compose mounted the `1026:100` host dir at the *leaf* (`…/data:/var/lib/alloy/data`); remotecfg/WAL/positions `mkdir` under `storage.path`, which needs a writable *parent*, but `/var/lib/alloy` was left root-owned. Fix (PR #5): mount the host dir **as** `/var/lib/alloy` and set `--storage.path=/var/lib/alloy`. Lesson: a state mount must give the process a writable *parent*, not just an owned leaf, when the process creates working subdirs.
2. **(Tooling) `diagnose.sh` hung on the Grafana log fetch.** `docker logs --tail 20` blocked on a chatty long-running container. Fix (PR #6): wrap in `timeout 5`.
3. **(Tooling) `diagnose.sh` port check used `ss`, absent on DSM.** Leaked `ss: command not found` and reported every port "not bound". Fix (PR #6): `netstat`-primary with `command -v` guards (DSM ships net-tools, not iproute2). Lesson: same "verify platform tooling" thread as F002/F003 — DSM's userland is not a generic Linux's.
4. **(Hygiene → the one real process gap) Tag-clobbering.** PR #4 added the Loki datasource under `docker/grafana/**` without bumping `VERSION`, so its merge re-pushed `v0.2.1` with new content (a mutable tag). Fix (PR #7): bump `VERSION` 0.2.1→0.3.0. → **carry-forward follow-up #1** (CI guard).
5. **(Self-inflicted, git process) Orphaned commits.** Three commits (unknown_service note, T102 disk-watch, retention runbook) were pushed to the PR #6 branch *after* PR #6 had merged, so they never reached `main`. Caught during a branch audit; rescued cleanly via cherry-pick into PR #8. Lesson: don't keep pushing to a feature branch after its PR merges — check merge state first, or branch fresh. No work lost, but avoidable churn.

**Benign behaviors documented (not fixes):**
- `timestamp too old` 400s on fresh deploy — Alloy ships the historical container backlog; Loki rejects >7-day lines per `reject_old_samples`. Self-corrects.
- Transient Alloy errors (`No such container` / `context canceled`) at a metrics-stack redeploy — `loki.source.docker` re-discovering recreated containers. Self-corrects.

---

## What went well

- **Phase 0 verification front-loading.** T086–T089 settled the entire topology (HTTP-no-TLS edge, native Alloy key/CORS, exact image pins, socket mechanism) *before* any config was authored. Result: zero topology rework mid-build. The one big network discovery (Mneme is HTTP → no TLS edge needed) collapsed the most complex part of the design (D5's reverse-proxy/cert story) at the cheapest possible moment.
- **Accumulated platform memories paid as design-time givens.** DSM UID restriction, Portainer relative-mount trap, ACL restart-loop recovery, no-`envsubst` — all cited from memory and designed around up front, not rediscovered at deploy. The only DSM surprise (Alloy's parent-mount) was a *new* class (process-creates-subdirs), not a re-hit of a known one.
- **Both pillars verified empirically on live traffic**, not just synthetically — real Mneme pino logs landing with clean labels, and the four-assertion beacon (key/CORS/trace-drop/landing) all green.
- **The trace-drop seam works as designed** — `output { traces = [] }` proven by a mixed payload (the trace span absent in Loki). The APM-deferral boundary is enforced in code, not just prose.

## What went poorly

- **Tag-clobbering slipped through** (fix-chain #4). Adding baked Grafana content without a `VERSION` bump should have been caught at PR-author time. → CI guard (follow-up #1).
- **Git-process churn** (fix-chain #5). Pushing to a merged PR's branch created orphaned commits and an extra rescue PR (#8). Self-inflicted; the lesson is mechanical (verify merge state before pushing).
- **PR sprawl during bring-up** — F004 spanned PRs #4–#8 across the feature + fixes. Acceptable for a deploy-and-iterate cycle, but a tighter pre-merge soak (deploy from the branch before merging to main) would have caught the Alloy mount + the tag-clobber before they hit `main`. (The constitution's "NAS runs main only" model trades this away deliberately at single-operator scale.)

---

## Carry-forward follow-ups

1. **Tag-clobbering CI guard** — *the one real process gap this deploy surfaced.* Add a step to `.github/workflows/build-grafana-image.yml` that **fails the build if `v${VERSION}` already exists as a published GHCR tag** (i.e. a Grafana-content change landed without a `VERSION` bump). Same flavor as the `honor_labels` count-gate: machine-enforce a discipline that's silent when violated. Sketch: query the GHCR tags API for `grafana:v${VERSION}`; if present on a content-changing push, fail with a "bump VERSION" message. Revisit: next Grafana-image change, or sooner as standalone hardening.
2. **Frontend symbolication (F012-side / future feature)** — F004 built the telemetry receiver only; there is **no source-map store and no symbolication path**. Production frontend exceptions land in Loki with *minified* stack traces. Readable production traces need a per-release source-map store + symbolication (at ingest or at read) — additional, unspecced work, owned by F012 or a dedicated future feature. The current Faro contract lists no source-map handling; F012 should not assume readable traces.
3. **Retention-test chunk-granularity** — the T102 short-test verified the compactor's *marker* creation on schedule (the authoritative "retention is active" signal), but physical single-line deletion is bounded by chunk granularity, so a single back-dated line isn't physically removed until its whole chunk expires. A cleaner future test pushes enough volume to fill *and* expire a complete chunk, then observes physical chunk deletion (file count / `du` drop), not just marker creation. Revisit: if retention behavior is ever in doubt, or as a one-time thoroughness pass.

---

## Meta-observation: methodology compounding

F004 was the **largest scope expansion of the four features** — metrics-only → a whole new observability category (logs + RUM), requiring a constitutional amendment (v1.3), a second compose stack, a new upstream pair (Loki + Alloy), a browser-facing receiver, and a cross-repo contract. By raw surface area it dwarfs F001–F003.

Yet it was the **smoothest deploy**, with the **fix-count trend continuing down**: F001 (13 in-flight, mostly systemic DSM discoveries) → F002 (4) → F003 (6, several latent doc-debt) → **F004 (1 stack-blocking)**. The non-blocking corrections were tooling robustness, version hygiene, and a git slip — not "the stack doesn't work."

Two compounding forces:
- **Phase 0 front-loading** (the spec-kit `/plan` + impl-time verification discipline) converted what would have been mid-build topology thrash into cheap up-front checks. The HTTP-no-TLS discovery alone removed an entire reverse-proxy/cert subsystem before a line of config was written.
- **The platform-memory corpus** turned DSM's idiosyncrasies (UID restriction, Portainer mounts, ACL recovery, no-envsubst) from deploy-time surprises into design-time constraints. F001 *discovered* these the hard way; F004 *assumed* them.

The discipline is paying compound interest: each feature's retro hardened the next feature's givens. The remaining gaps (tag-clobber CI guard) are now about hardening the *pipeline*, not the *platform* — a sign the platform itself is well-characterized.

---

## Memory system state at close

*(Finalize at close — candidates, not yet written.)*

- `project_overview.md` already updated to v1.3.0 (two-subsystem budgets, F004 active) during the amendment.
- **Candidate new memory:** the logs/RUM subsystem exists — Loki+Alloy, second compose stack, the Faro receiver contract + its location in Mneme's `docs/observability.md`. (Decide at close whether this is derivable from the repo or worth a memory.)
- **Candidate:** the tag-clobbering lesson, *if* it's not fully captured by the CI guard once built (a guard makes the memory redundant).
- Run the same pre-close audit discipline as F003: verify no stale/contradictory memories, regenerate `MEMORY.md` index.

---

## T106 — 24-hour observation outcomes

*(PLACEHOLDER — fill in after the window closes. This window characterizes ingestion stability + disk-growth RATE; it does NOT characterize retention-deletion, which T102 verified separately — a 7-day compactor can't fire in 24h.)*

**Window:** <start> → <start + 24h>

**Ingestion stability:**
- Alloy keeps up with real container-log load (no growing lag / dropped batches): <result>
- Faro receiver stays responsive: <result>
- No crash-loops; restart counts flat for loki + alloy: <result>
- Observed memory vs. the 500 MB logs/RUM cap (target < 70%): loki <obs> / alloy <obs> / total <obs>

**Disk-growth rate:**
- `loki/data` footprint at start: <e.g. 764K> → at +24h: <obs>
- Extrapolated 7-day footprint: <obs> — comfortably under the disk-watch threshold? <y/n>

**Metrics subsystem unaffected:** 6 containers Up, 600 MB cap held, dashboards rendering: <result>

**Anomalies:** <none / list — anomalies generate follow-up issues; they do not block F004 close, per F001 T028 / F002 T056 / F003 T083 precedent>

**Verdict:** <PASS / issues>
