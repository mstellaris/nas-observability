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

### Updating an upstream image (Prometheus / cAdvisor / node_exporter)

1. Bump the image tag in `docker-compose.yml` to the new upstream version.
2. Verify `mem_limit` is still appropriate for the new version (check release notes for memory behavior changes).
3. Update the compliance checklist in the PR description.
4. Merge to `main`, then redeploy via Portainer as above.

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
