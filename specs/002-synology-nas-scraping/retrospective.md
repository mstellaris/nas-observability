# Retrospective: Synology NAS Scraping & Dashboards

**Feature Branch:** `002-synology-nas-scraping`
**Spec:** [`spec.md`](./spec.md) · **Plan:** [`plan.md`](./plan.md) · **Tasks:** [`tasks.md`](./tasks.md)
**Status:** **Complete (2026-04-25)** — all acceptance scenarios passed including T055 + T056
**Retrospective written:** 2026-04-24, finalized 2026-04-25

---

## Outcome

Feature 002 extended F001's stack with Synology-specific metrics and three NAS dashboards. Phase 7 (DS224+ deploy) completed cleanly, with only 4 in-flight fixes compared to F001's 13 — the direct payoff from Constitution v1.1's platform constraints doing their job at design time.

**Stack state post-F002:** 5 containers running (Prometheus, Grafana, cAdvisor, node_exporter, snmp-exporter), 4 Prometheus scrape jobs all UP, 4 Grafana dashboards all rendering live data. Memory allocation at 600 MB cap exactly; observed usage well below. 24-hour stability observation (T055/T056) passed with no scrape-duration drift and no NAS CPU footprint from scrapes — see T055 + T056 outcomes section below.

---

## What shipped

**Core scraping + dashboards:**
- `snmp-exporter` service on port 9116 running as `user: "1026:100"` (v1.1 Platform Constraint from day one, no rediscovery).
- `config/snmp_exporter/snmp.yml.template` — community-sourced (wozniakpawel) template, 2345 lines, v2c auth, rendered on the NAS by `init-nas-paths.sh` via `sed` substitution from a local `.community` file.
- Three NAS dashboards baked into the custom Grafana image at `/etc/grafana/dashboards/`: **NAS Overview** (7 panels), **Storage & Volumes** (5 panels), **Network & Temperature** (5 panels). All tagged per the v1.1-aligned tag convention.
- Prometheus scrape job `synology` with 60s interval and 10s timeout (D3 Tier 1 measurement: 0.61s walk, 16× headroom).

**Operational improvements carried from F001:**
- `scripts/diagnose.sh` — one-command diagnostic dump. 5 sections (states, logs, stats, bind mounts, ports) with color/TTY handling, exit codes 0/1/2, special-case reporting for the SNMP bootstrap-not-rendered state. Runtime 0.3s local, well under NFR-11's 10s.
- GHA action Node.js 24 migration — `v4/v3/v3/v6` bumped to `v6/v4/v4/v7`. 5 months ahead of the 2026-09-16 Node.js 20 removal deadline.

**Supporting artifacts:**
- `docs/snmp-setup.md` — DSM SNMP enablement runbook (6 steps + troubleshooting).
- `docs/deploy.md` "Updating `snmp.yml`" flow section.
- `docs/ports.md` 9116 claimed.
- `.env.example` + `.gitignore` updated (secret-hygiene: `*.community` never committed).
- `docs/setup.md` cross-reference to SNMP setup flow.

---

## The Phase 7 fix-chain

Four in-flight corrections during deploy. Much smaller than F001's 13, because the systemic DSM-platform fixes are now constitutional:

1. **`envsubst` not available on DSM.** Plan specified `envsubst` for template rendering. DSM doesn't ship `gettext`. Pivoted to `sed 's|${VAR}|'"$val"'|g'` — works on both GNU and BSD sed. Memory saved as `project_dsm_no_envsubst.md`.
2. **snmp_exporter v0.28's `/-/ready` endpoint doesn't exist.** Plan's healthcheck assumed a readiness endpoint that's only in later versions. Switched healthcheck to `/metrics` which is always exposed and always returns 200 when the exporter is healthy. Portable across snmp_exporter versions.
3. **`.community` file mode leaked from 600 → 755.** Init script's `chmod -R 0755` on `BIND_PATHS` cascaded into the secret file created by the operator. Fixed by dropping `-R` (the mode-0000 gotcha only applies at directory level) and adding a defensive `chmod 600` on `.community` after the loop.
4. **DSM firewall prompt on Apply.** Runbook didn't mention that enabling SNMP triggers a DSM firewall notification for UDP 161. Closed the doc gap during the operator's first walk.

**Three panel polish items after T053** (not fixes, just ergonomics):
- Storage pool hidden from Per-Volume Usage bargauge (was showing 100% red for a fully-allocated pool, alarming but harmless)
- Disk label harmonization (IOPS panel `sata1/sata2` → `Disk 1/Disk 2` via `label_replace`, matching the temperature panels)
- Virtual interface exclusion from throughput panel (`docker.*|lo|sit.*|veth.*|br-.*` filtered)

Total commits during deploy + polish: 8. F001 was 13.

---

## What went well

- **Constitution v1.1 Platform Constraints earned their keep.** DSM UID restriction, bake-vs-mount path separation, and datasource UID determinism were design-time givens, not deploy-time rediscoveries. F002 plan cited all three explicitly; zero Phase 7 issues traced to any of them.
- **D4 traceability gate (T041) held.** All 18 planned panels shipped with confirmed OIDs in the committed template. Zero "no data for three months" shipped. The single presentation adjustment (fan RPM → fan status enum) was caught at gate time, not deploy time.
- **diagnose.sh paid dividends immediately.** T032 caught a real bug (port 9116 reporting "not bound" even when bound) on the first run against the F001 stack, fixed pre-Phase 2. Rest of Phase 7 used it for every deploy sanity check.
- **D3 scrape-timing validation resolved concretely.** 5-sample measurement (0.61s max) → tier-matched threshold → recorded both in the PR and in `plan.md` §D3. No PR archaeology needed at T043.
- **Phase ordering flipped from F001 was the right call.** Operational tooling (diagnose.sh, GHA migration) landed first in Phase 1, so every later phase had the debug tool available. F001 discovered most deploy pain in Phase 8 without baseline tooling; F002 inverted that and saw visibly fewer round-trips.
- **Spec D2's fallback provision unblocked F002 cleanly.** Community `snmp.yml` saved roughly a day of MIB-file-on-NAS tooling friction that walkgen would have required. Marked as a follow-up without making the main path slower.

## What went poorly

- **Plan assumed `envsubst` and `/-/ready` existed without verifying at plan time.** Both are generic Linux/Prometheus-ecosystem conventions that don't universally hold (DSM's stripped-down shell doesn't ship gettext; snmp_exporter v0.28 predates the readiness endpoint). The F001 retrospective's takeaway — "verify assumptions about the platform at plan time, not deploy time" — got reinforced here.
- **`.community` mode leak was a latent F001 bug.** F001's `chmod -R 0755` worked because F001 had no secret files in bind mounts. F002's first secret file inherited the cascade. Lesson: when adding a new file into an existing directory structure, audit the init-script logic for assumptions that were valid at the time but aren't anymore.
- **Didn't catch the DSM firewall prompt in the runbook authoring.** `docs/snmp-setup.md` Step 1 was written without knowing DSM would prompt. Caught on the operator's first walk; added inline. Lesson: for NAS-side UI walkthroughs, one dry-run on a fresh NAS would catch a lot of doc gaps.

---

## Carry-over to Feature 003

Two items deferred during F002 and explicitly pulled forward into F003's scope for consideration:

1. **Replace `snmp.yml.template` with walkgen output** (Spec D2 primary path). The currently-committed 2345-line community config works fine but contains metric definitions for OIDs the three dashboards don't consume. Walkgen against this specific DS224+ + post-walk pruning would yield a tighter ~300–500 line template with zero phantom metric definitions. Not blocking — the community version is functionally complete and the `TODO: replace with walkgen output` comment in the template header already flags it. Worth doing as a post-F002 polish PR when any of the following triggers fires:

   - **DSM major upgrade** (OID tree may shift; community config could go stale)
   - **A new panel needs an OID the community config doesn't expose** (forces walkgen anyway)
   - **The 2345-line config begins affecting scrape duration trends** (currently 600ms baseline; ample headroom, no pressure)
   - **Six-month routine maintenance window**

   If none of these fire, the community config remains in production indefinitely — that's an acceptable steady state, not a known debt. The `TODO: replace with walkgen output` comment in the template header serves as the in-code reminder.

2. **Multi-arch Grafana image** (amd64 + arm64) per Spec D6. Deferred in F002 because QEMU-based arm64 builds in GHA triple build time (~40s → ~2–3 min per push) without concrete dev-frequency justification yet. Native arm64 GHA runners are in limited beta as of early 2026; revisit when they're generally available — that eliminates the emulation tax and makes multi-arch essentially free.

Both are cataloged here rather than dropped silently; both have concrete revisit criteria. When F003's `/specify` happens, the spec can cite this retrospective for context and decide whether to pull either into F003's scope or defer again with an updated criterion.

## Feature 003 preview

F003 opens with these priors from F002 memory:

- **Application scraping** starts with Mneme's `/metrics` endpoints. Mneme-side instrumentation is a separate concern; F003's job is the scrape + dashboard side.
- **Consumer-dashboard CI sync** finally ships. The mechanism was described in the constitution at ratification (v1.0.0) but intentionally deferred. F003 adds the CI workflow step that clones each consumer repo's `main`, copies its `ops/dashboards/`, and triggers a Grafana image rebuild.
- **Cross-repo dependency:** F003's consumer-dashboard sync mechanism depends on Mneme Feature 008 (the instrumentation contract) shipping first — otherwise the CI workflow has nothing to clone (Mneme's `ops/dashboards/` won't exist yet) and no `/metrics` endpoints to scrape. If Mneme F008 isn't ready when F003 work begins, F003 can ship the infrastructure half (CI workflow scaffolding, postgres_exporter, nightly GHA `schedule:` trigger) without the Mneme-specific scrape job and dashboards, deferring those to F004. Path A from F002's close-out plan (pivot to Mneme F008 first, then return to F003) avoids the split.
- **Nightly GHA `schedule:` trigger** deferred from F001 ships with F003. The rationale for the deferral was "no consumer dashboards to propagate yet"; F003 removes that rationale.
- **postgres_exporter** (reserved at port 9187) joins the stack. Memory allocation within the 600 MB cap; revisit cAdvisor's observed 30 MB / 90 MB limit for potential donation.
- **All three v1.1 Platform Constraints apply from F003 day one**: Mneme scraping from inside host-networked containers to Mneme's app port, Grafana consuming Mneme dashboards via the sync mechanism into `/etc/grafana/dashboards/mneme/`, datasource references by explicit UID.
- **The memory system now has 10 entries** covering DSM ACL recovery, DSM UID restriction, Portainer workspace, bind-mount masking, DSM-no-envsubst, and more. F003 should hit near-zero of these surprises.

---

## Memory system state at close

No new memories added during F002 Phase 7 beyond the `project_dsm_no_envsubst.md` one saved when `envsubst` pivot happened. Total persistent memories: 10 (was 9 at F001 close).

Notable that F002's deploy surfaced no new *systemic* DSM gotchas — the envsubst issue is a specific-tool concern, not a constitutional pattern. Suggests the constitution's v1.1 amendments covered the breadth of DSM-platform quirks accurately.

---

## T055 + T056 — observation outcomes (2026-04-25)

**T055 NFR-9 — scrape duration stability:** PASS. Over the 24-hour window, the `synology` scrape job's baseline held flat at ~600ms (matching T039's 0.61s measurement). Intermittent spikes reached ~1s in a handful of cases — well within the 10s timeout's ~10× headroom — and showed no upward drift. No leak indicator (would manifest as a climbing line over time). cAdvisor at ~150–200ms, node_exporter at ~50–80ms, Prometheus self-scrape near zero, all stable.

**T056 NFR-10 — no scrape-correlated CPU pattern:** PASS. NAS Overview CPU graph over 24h shows three discrete workload spikes (afternoon, evening, morning — real activity events) on a flat ~5% baseline. Not the regular 60s sawtooth that would indicate SNMP scrape overhead; the SNMP daemon's footprint is below CPU panel resolution. RAM held flat at 5–7% throughout. Load Average tracked CPU activity as expected (transient spikes, no sustained elevation).

**T028-equivalent (conditional cAdvisor tuning) was not needed in F002**: cAdvisor's allocation is unchanged from F001 and observed memory remained well below its 90M cap.

Feature is formally complete.
