# Deploy

Updating the running nas-observability stack on the DS224+. For first-time setup, see `docs/setup.md` instead.

## Flows

### Updating the custom Grafana image

Updates to dashboards, provisioning, or anything under `docker/grafana/` flow through the CI workflow:

1. Make the change on a branch, open a PR.
2. Once merged to `main`, the `Build Grafana image` workflow fires and publishes two new GHCR tags: `v<semver>` (if `VERSION` was bumped) and `sha-<short>`.
3. In `docker-compose.yml`, bump the Grafana image tag to the new value. Commit and push (this doesn't trigger a rebuild — path filters exclude `docker-compose.yml`).
4. In Portainer, open the stack → **Editor** → paste the new compose (or use **Pull and redeploy**) → deploy with **Re-pull image** enabled.

Grafana restarts with the new image. Prometheus, cAdvisor, and node_exporter are not affected (their image tags live on their own upgrade cadence — each bump is its own PR with the compliance checklist).

### Updating Mneme dashboards

Mneme dashboards live in `docker/grafana/dashboards/mneme/` (alongside `stack/` and `synology/`). The same flow applies whether you're authoring a new dashboard or updating an existing one — edit directly against the deployed NAS Grafana, then export and commit:

1. Open the deployed Grafana in your browser at `http://<nas-ip>:3030` (the stack uses host networking, so Grafana is LAN-reachable directly — no SSH tunnel needed). Log in, navigate to the Mneme folder, open the dashboard you're editing. Temporarily set `editable: true` in the dashboard JSON if it's currently locked down.
2. Iterate until panels render correctly. Once done: **Share → Export → Save to file**. Grafana injects four export-environment keys (`__inputs`, `__elements`, `__requires`, `iteration`) that produce noisy diffs across re-exports.
3. Strip the export noise before committing:
   ```bash
   ./scripts/strip-grafana-export-noise.sh docker/grafana/dashboards/mneme/<file>.json
   ```
   The script is idempotent; safe to re-run. It only deletes the four export keys — panel/query/layout JSON is preserved exactly.
4. Commit the cleaned file. The CI workflow rebuilds the Grafana image; deploy follows the "Updating the custom Grafana image" flow above.

The same flow applies to `stack/` and `synology/` dashboard updates.

### Updating an upstream image (Prometheus / cAdvisor / node_exporter)

1. Bump the image tag in `docker-compose.yml` to the new upstream version.
2. Verify `mem_limit` is still appropriate for the new version (check release notes for memory behavior changes).
3. Update the compliance checklist in the PR description.
4. Merge to `main`, then redeploy via Portainer as above.

### Updating `snmp.yml`

`snmp.yml` is rendered on the NAS by `scripts/init-nas-paths.sh` from two inputs: the committed `config/snmp_exporter/snmp.yml.template` and the NAS-local `/volume1/docker/observability/snmp_exporter/.community` secret file (see `docs/snmp-setup.md` §Step 3). To update:

1. Edit `config/snmp_exporter/snmp.yml.template` in the repo — walk subtrees, metric definitions, module structure, but never the community string (which stays as the `${SYNOLOGY_SNMP_COMMUNITY}` token). Commit and push.
2. Over SSH on the NAS, refresh the host config:
   ```bash
   curl -fsSL -o /tmp/init-nas-paths.sh https://raw.githubusercontent.com/mstellaris/nas-observability/main/scripts/init-nas-paths.sh
   sudo bash /tmp/init-nas-paths.sh
   ```
   (DSM's default `/bin/sh` doesn't support process substitution, so download-then-run rather than `<(...)`.) The init script is idempotent and re-rendering from the new template is a no-op for everything else.
3. Restart the `snmp-exporter` container so it reloads `/etc/snmp_exporter/snmp.yml`: `sudo docker restart snmp-exporter`. SNMP exporter doesn't have a lifecycle-reload endpoint like Prometheus does, so a restart is required.

If the container fails to restart cleanly, `docker logs snmp-exporter` typically shows a YAML parse error or a reference to an OID the NAS doesn't expose.

### Updating `prometheus.yml`

`prometheus.yml` lives in a host path (`/volume1/docker/observability/prometheus/prometheus.yml`), not inside the Portainer clone. See `docs/setup.md` for why. To update it:

1. Edit `config/prometheus/prometheus.yml` in the repo. Commit and push.
2. Over SSH on the NAS, refresh the host-side config:
   ```bash
   curl -fsSL -o /tmp/init-nas-paths.sh https://raw.githubusercontent.com/mstellaris/nas-observability/main/scripts/init-nas-paths.sh
   sudo bash /tmp/init-nas-paths.sh
   ```
   (DSM's default `/bin/sh` doesn't support process substitution, so download-then-run rather than `<(...)`.) The init script is idempotent and re-running it refreshes `prometheus.yml` to the new committed version.
3. Tell Prometheus to reload without restarting: `curl -X POST http://localhost:9090/-/reload` (from the NAS shell, or use `<nas-ip>:9090` from your workstation).

If the reload endpoint returns non-200, `docker logs prometheus` will show the config error. Fix the repo, push, re-run steps 2–3.

### Rollback

Point the image tag back to a previous value:

- For Grafana: set `ghcr.io/mstellaris/nas-observability/grafana:<previous-tag>` in compose, commit, redeploy.
- For upstream images: set the previous pinned version in compose, commit, redeploy.

Prometheus TSDB and Grafana state are bind-mounted to `/volume1/docker/observability/`, so rollback preserves history. Dashboards and provisioning are baked into the Grafana image, so rolling back the image tag also rolls back dashboards — exactly as intended.

### Adding a new service

Every service addition must satisfy the [compliance checklist](../.github/pull_request_template.md):

- [ ] Pinned image version (no `:latest`).
- [ ] Explicit `mem_limit` declared.
- [ ] Total budget ≤ 600 MB after the change (include arithmetic in PR description).
- [ ] Port declared in `docs/ports.md` within an existing reserved range.
- [ ] Bind mount documented if the service persists state.

The PR template pre-fills this checklist. Reviewers reject PRs that skip it.

## Speeding up cold deploys

The first deploy against an empty Docker cache pulls ~700 MB of images over residential bandwidth. If NFR-2b (5 minutes) consistently misses, pre-pull the images over SSH before using Portainer:

```bash
# On the NAS:
docker pull prom/prometheus:v3.1.0
docker pull gcr.io/cadvisor/cadvisor:v0.49.1
docker pull prom/node-exporter:v1.8.2
docker pull ghcr.io/mstellaris/nas-observability/grafana:v0.1.0
```

Portainer's deploy then skips the pulls and lands in ~1 minute (NFR-2a warm-cache target).

## When NOT to deploy

If the current Grafana image tag in `docker-compose.yml` does not yet exist in GHCR (e.g., because a CI build is still running or failed), Portainer's pull step fails. Either wait for the build to land, or roll the tag back to a known-good one.
