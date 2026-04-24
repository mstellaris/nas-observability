# Retrospective: Infrastructure Bootstrap

**Feature Branch:** `001-infrastructure-bootstrap`
**Spec:** [`spec.md`](./spec.md) · **Plan:** [`plan.md`](./plan.md) · **Tasks:** [`tasks.md`](./tasks.md)
**Status:** Deployed and running on the DS224+; T027 (memory observation) outstanding
**Retrospective written:** 2026-04-24

---

## Outcome

The stack is live on the Synology DS224+. All four containers — Prometheus, Grafana, cAdvisor, node_exporter — are up, every health check passes, all three Prometheus scrape targets report `UP`, Grafana renders the baked `Stack Health` dashboard with correct image metadata, and total memory usage is within the constitutional 600 MB cap. CI publishes the custom Grafana image to GHCR on every push to `main`. Constitution principles I–IV are all satisfied; Principle V (alerting) is explicitly out of F001 scope.

What's outstanding: **T027** — observe memory over ~1 hour of real scraping and confirm each `mem_limit` is not breached. If cAdvisor breaches 90 MB, **T028** (conditional tuning) fires. Based on the scrape-duration values seen immediately post-deploy (cAdvisor ~150–250 ms at 30s intervals, node_exporter ~50–80 ms at 15s), cAdvisor is the only realistic candidate for a squeeze, and even it is likely to land comfortably.

---

## What shipped

**13 commits** across 9 implementation phases. Per-commit history reads as a case study of "what DSM 7.3 changes about upstream Docker recipes."

| Phase | Work                                                                           |
|-------|--------------------------------------------------------------------------------|
| 1–3   | Compose skeleton (4 services, 560 MB allocated, host networking, pinned tags)  |
| 4     | Custom Grafana image: provisioning + `Stack Health` dashboard + `inject-build-metadata.sh` |
| 5     | GHA workflow publishing `v<semver>` + `sha-<short>` tags to GHCR               |
| 6     | `scripts/init-nas-paths.sh` for NAS-side bind-mount init                       |
| 7     | `docs/setup.md` (troubleshooting), `docs/deploy.md`, `docs/ports.md`, PR template |
| 8     | DS224+ cold deploy — where reality happened (see below)                        |
| 9     | T027 pending                                                                   |

Every commit is on `main`, including the messy Phase 8 fix-chain, so the history is honest about what was discovered when.

---

## The Phase 8 fix-chain (13 DSM-specific adjustments)

Each of these was discovered by a failed deploy with a specific error message, fixed in-flight, and committed individually with the error quoted in the commit body. All of them trace to the same root observation: **upstream Docker recipes assume a standard Linux distro; DSM 7.3 differs in small but load-bearing ways**.

### Image and CI (caught at Phase 4 checkpoint — before production hit them)

1. **`grafana/grafana:11.4.0-oss` doesn't exist.** Real OSS-only tag is `grafana/grafana-oss:11.4.0` (separate repo). Caught by local `docker build` failing at `FROM`.
2. **Dockerfile `USER` switching needed.** Grafana's base image runs as `grafana` (non-root); `COPY` leaves files root-owned; `sed -i` during dashboard substitution failed with permission denied. Fix: `USER root` for build steps, `USER grafana` at the end, plus `chown -R grafana:root` on the provisioning and dashboards paths.
3. **Datasource `uid` needs to be explicit.** Grafana auto-generates UIDs when unspecified, which can differ between environments and break dashboards referencing `datasource.uid`.

Phase 4 → Phase 5 checkpoint caught all three. This is exactly why that checkpoint exists.

### Portainer mechanics (first production deploy)

4. **Relative-path bind mounts fail.** Portainer's "Repository" deploy clones into its own internal workspace (`/data/compose/<id>/`) — which is inside Portainer's container and not visible as that path on the host filesystem. A compose reference like `./config/prometheus/prometheus.yml` fails. Fix: place config files at absolute host paths, populated by the init script via `curl` from the repo's raw URL.

### DSM host quirks (iterative discovery through deploy attempts)

5. **`/` can't be mounted `rslave` on DSM.** DSM 7.3 mounts `/` as private (the Linux default); Docker refuses `rslave` without a shared or slave source. Dropped `rslave` from node_exporter's `/` mount.
6. **Docker root isn't `/var/lib/docker`.** DSM's Container Manager uses `/volume1/@docker`. Verify on any DSM NAS with `docker info | grep "Docker Root Dir"`.
7. **`/dev/disk` isn't populated.** Removed the cAdvisor mount entirely — loses disk-label fidelity on per-container I/O metrics, but host-level disk telemetry lives under the SNMP exporter in F002 anyway.
8. **cAdvisor's `accelerator` metric was removed in v0.49.1.** Dropped from the `--disable_metrics` list.
9. **DSM blocks low UIDs from writing to `/volume1/`.** Not an ACL, not a POSIX issue — a DSM security-model restriction on system UIDs like `nobody` (65534) and `grafana` (472). Fix: run Prometheus and Grafana as the DSM admin UID (`1026:100` for `superman:users`) via compose `user:` and match the chown in the init script.
10. **DSM creates bind-mount dirs with POSIX mode `0000`.** `mkdir -p` via shell followed by `chown` landed owner correctly but left mode at `0000` (an ACL mask behavior specific to DSM). Fix: explicit `chmod -R 0755` in the init script after chown.
11. **Port 8080 was already owned by `mneme-caddy`.** Moved cAdvisor to 8081 within the same reserved range. Port allocation table updated. Lesson: check `ss -tlnp` before choosing a port, even inside a reserved range.
12. **cAdvisor's baked `HEALTHCHECK` hardcodes `:8080`.** With `--port=8081` + `network_mode: host`, the baked check hit `mneme-caddy` instead, reporting cAdvisor unhealthy even though it was serving metrics correctly. Override in compose.
13. **Bind mount masks baked dashboards.** The Dockerfile copied `stack-health.json` into `/var/lib/grafana/dashboards/`, but compose bind-mounts `/var/lib/grafana` — the empty host directory hid the baked content at runtime. Grafana login worked, datasource was provisioned, but the Dashboards UI was empty. Fix: bake dashboards under `/etc/grafana/dashboards/` (not a bind-mount target). `/var/lib/grafana` remains for genuinely persistent state (sqlite + plugins).

---

## What went well

- **Constitution-first discipline paid off.** Every service change went through the compliance checklist (pinned image, `mem_limit`, 600 MB total, port in the table, bind mount documented). The 600 MB cap and `mem_limit` declarations meant nothing grew silently under pressure.
- **The Phase 4 → Phase 5 checkpoint caught real bugs.** Three Dockerfile/provisioning issues (wrong base tag, `USER` switch, datasource UID) would have silently baked broken images into GHCR without the local build test before CI activation. Keep this checkpoint in future features.
- **Commit-per-fix granularity.** Each Phase 8 fix is its own commit with the triggering error in the body. The main history is a searchable index of DSM quirks. Future-me grepping for "Bind mount failed" will find the commit that fixed it.
- **Memory system is genuinely useful.** Eight persistent memories capture lessons that span features: DSM ACL recovery, DSM UID restriction, Portainer workspace behavior, bind-mount masking, push authorization, etc. F002's first deploy should hit near-zero of these surprises.
- **Spec-kit's `/specify` → `/plan` → `/tasks` → `/implement` flow held up.** The plan was wrong on details but the structure (phases, checkpoints, conditional tuning) absorbed the chaos without needing to restart.

## What went poorly

- **Plan assumed the happy path on platform specifics.** The plan used upstream-Docker conventions (`/var/lib/docker`, `/dev/disk`, `rslave` propagation, image-default container users, port 8080) without verifying them against DSM 7.3. Of the 13 Phase 8 fixes, 9 trace to "the plan treated Linux as Linux and didn't account for DSM-specific behavior." Next feature: build in a "platform quirks pass" on the plan before it ships.
- **Didn't verify image tags exist before pinning them.** `grafana/grafana:11.4.0-oss` was written confidently in the plan but doesn't exist. A 30-second `docker manifest inspect` at plan time would have caught it. Add this to the plan review checklist.
- **Multiple deploy round-trips consumed operator time.** 13 fixes meant 13 deploy/log/fix cycles, each with workstation-to-NAS latency. Batching diagnostics (asking for multiple log tails + `ls` outputs in one prompt) helped, but the raw count of round trips still surprised us. Future-feature-ergonomics idea: ship a short diagnostic script with the init script that dumps the 4–5 most common "first-deploy is broken" signals in one command.
- **README status field was briefly inaccurate.** "first NAS deploy verification in progress" was true until it wasn't — the retrospective and this update fix that. Lesson: status fields age; audit them at every feature-close.

---

## Takeaways for F002+

1. **DSM 7.3 is the default assumption, not Linux.** Before writing any new service config:
   - Verify paths exist on the NAS (`ls -ld /expected/path`).
   - Verify UIDs the image runs as aren't low/system UIDs (DSM blocks writes from those to `/volume1/`) — if they are, override to `1026:100`.
   - Verify ports are free (`ss -tlnp | grep <port>`), even within a reserved range.
   - Verify mount propagation flags (`rslave` won't work; plain `ro` does).
   - Check baked content paths vs. bind-mount targets — never bake repo-owned config under a parent that gets bind-mounted.

2. **F002's SNMP exporter and Alertmanager will almost certainly hit the UID-restriction pattern.** Plan on `user: "1026:100"` in compose from the start; chown matching bind mounts in the init script. No need to rediscover.

3. **Verify image tags exist at plan time, not at build time.** Cheap check, high payoff.

4. **Keep the Phase 4 → Phase 5 checkpoint in every feature that builds a custom image.** It did its job in F001 and will keep doing it.

5. **Before adding a nightly CI trigger in F003** (when the consumer-dashboard sync mechanism ships), verify the repo is public in the GHA context and GHCR auth survives unattended runs. The first-push GHCR gotcha from F001 (package-visibility-private) is a one-time event but analogous issues can bite scheduled runs.

6. **Operator-side diagnostics want a one-command dump.** Future task idea: `scripts/diagnose.sh` that shows container states + last 20 lines of each log + `docker stats --no-stream` + host ownership of bind mounts + port-in-use check on the stack's declared ports. Cuts the multi-round-trip shape of Phase 8 debugging.

---

## Memory system state at close

Eight memories persist across sessions:

- `user_methodology.md` — spec-kit flow
- `project_overview.md` — nas-observability project shape + constraints
- `reference_mneme_dashboards.md` — Mneme dashboard location
- `project_dsm_acl_recovery.md` — `synoacltool -del` recovery
- `project_dsm_uid_restriction.md` — DSM blocks low UIDs on /volume1
- `project_portainer_bind_mounts.md` — config files need absolute host paths
- `project_bind_mount_masks_baked_files.md` — split config from state paths
- `feedback_push_authorization.md` — standing OK to push routine main

These are the load-bearing learnings. F002 opens with them already in context.

---

## Outstanding

- **T027** — 1-hour memory observation. When this closes cleanly, F001 is formally done and we can open Feature 002.
- **Follow-up items noted but not blocking:** Node.js 20 deprecation in GHA actions (ship minor bumps before 2026-09-16); multi-arch Grafana image if local dev on Apple Silicon becomes valuable; `scripts/diagnose.sh` for future features. None of these are on F001's critical path.
