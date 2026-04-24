# Setup

First-time deployment of the nas-observability stack on a Synology DS224+ running DSM 7.3. Do this once per NAS; subsequent updates follow `docs/deploy.md` instead.

## Prerequisites

On the NAS:

- **DSM 7.3** (tested; older versions may work but are not supported).
- **Container Manager** installed via Package Center. This ships with Docker Engine + Compose v2.
- **Portainer** installed as a container, reachable via the LAN.
- **SSH enabled** (Control Panel → Terminal & SNMP → Enable SSH service) and an admin account you can `sudo` with.
- The admin user is in the `docker` group (DSM adds this automatically once Container Manager is installed).

On your workstation:

- `git` — to push updates that CI picks up.
- A browser — to reach Portainer and Grafana.

## One-time NAS initialization

The stack binds persistent state to `/volume1/docker/observability/`. Before the first deploy, create those paths with correct ownership, clear DSM's ACLs (which override POSIX permissions and are the single most common source of Docker restart loops), and pull `prometheus.yml` into a host path the stack bind-mounts.

The init script does all of this. Fetch and run it directly from the repo:

```bash
# Over SSH on the NAS:
curl -fsSL -o /tmp/init-nas-paths.sh https://raw.githubusercontent.com/mstellaris/nas-observability/main/scripts/init-nas-paths.sh
sudo bash /tmp/init-nas-paths.sh
```

Expected output:

```
  /volume1/docker/observability/prometheus/data  (owner 1026:100)
  /volume1/docker/observability/grafana/data  (owner 1026:100)
  /volume1/docker/observability/prometheus/prometheus.yml  (owner 1026:100, mode 644)

NAS paths initialized under /volume1/docker/observability. Populate GRAFANA_ADMIN_USER and
GRAFANA_ADMIN_PASSWORD in Portainer's stack environment variables, then deploy the stack from
docker-compose.yml.
```

`1026:100` is the UID:GID of this NAS's admin user (`superman:users`). If you're forking onto a different NAS, check with `id <admin-user>` and update both `scripts/init-nas-paths.sh` (the `OWNER` variable) and `docker-compose.yml` (the `user:` directives on the prometheus and grafana services) to match.

The script is safe to re-run — `mkdir -p` and `chown` are idempotent, and the curl step refreshes `prometheus.yml` to the latest committed version. Re-run it any time you bump `prometheus.yml` in the repo (then `curl -X POST http://<nas-ip>:9090/-/reload` to tell Prometheus to pick up the new config without a restart).

**Why `prometheus.yml` lives in a host path instead of being mounted relative from the compose:** Portainer's "Repository" deploy mode clones the repo into its own internal workspace (`/data/compose/<id>/`), which is inside Portainer's container and not visible as that path on the host filesystem. A bind mount declared as `./config/prometheus/prometheus.yml` would resolve on the host to a path that doesn't exist. Host-path mounts dodge this entirely.

**Synology SNMP enablement** is NOT part of this setup — SNMP scraping ships with Feature 002, and its NAS-side configuration (Control Panel → Terminal & SNMP → SNMP tab) is documented there. F001 needs nothing SNMP-related.

## Populate `.env` in Portainer

The stack reads two environment variables. Copy `.env.example` contents into Portainer's stack environment variables field when you create the stack (next section). Change `GRAFANA_ADMIN_PASSWORD` to a real value — the committed default is a tripwire, not a usable credential.

```
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<strong-password>
```

Never commit the real `.env` to git. The repo's `.gitignore` already excludes it.

## First deploy via Portainer

1. In Portainer, go to **Stacks → Add stack**.
2. Build method: **Repository**.
3. Repository URL: `https://github.com/mstellaris/nas-observability` (or SSH equivalent).
4. Reference: `refs/heads/main`.
5. Compose path: `docker-compose.yml`.
6. Environment variables: paste the two `GRAFANA_*` keys from above.
7. **Deploy the stack**.

The first deploy pulls four images (~700 MB total) over your internet connection. On residential bandwidth budget ~5 minutes for a cold cache. If you need to shave time, pre-pull the images over SSH first — see `docs/deploy.md` §Speeding up cold deploys.

## Verification

Once Portainer shows all four containers as "running":

1. Visit `http://<nas-ip>:9090/targets` → all three scrape targets (`prometheus`, `node_exporter`, `cadvisor`) should show state `UP`.
2. Visit `http://<nas-ip>:3030` → Grafana login with the `.env` credentials.
3. In Grafana, open the **NAS Observability — Stack Health** dashboard (under Dashboards, tagged `stack-health`). After ~30 seconds of scraping, the three UP stat panels should read UP, the TSDB series count should be non-zero, and the scrape duration time series should be populating.
4. The Build Metadata panel at the bottom should show the image's semver and short SHA — confirming the custom image was built and published correctly.

If any of these fail, jump to **Troubleshooting** below.

## Troubleshooting

### Container restart loop — permission denied on /volume1 bind mount

**Symptom:** Prometheus or Grafana keep restarting; `docker logs <container>` shows permission-denied writes to a bind-mounted path. Example errors:
```
Prometheus:  open /prometheus/queries.active: permission denied
Grafana:     mkdir: can't create directory '/var/lib/grafana/plugins': Permission denied
```
`ls -ln /volume1/docker/observability/<service>/data` shows correct ownership matching the container's user.

**Cause:** DSM 7.3 blocks writes from low/system UIDs (like `nobody`/65534 or `grafana`/472) to `/volume1/` paths, regardless of POSIX permissions. This is a DSM security-model restriction, not an ACL. Running the container as its image-default user fails even when `chown` says the user owns the target directory.

**Recovery:** Run the container as the DSM admin UID instead of the image default. This repo already does that — `docker-compose.yml` sets `user: "1026:100"` on prometheus and grafana, and `scripts/init-nas-paths.sh` chowns bind mounts to match. If you see this error on this NAS, re-run the init script (something drifted); if you see it on a fork, the admin UID differs — update the hardcoded `1026:100` in both files to your NAS's admin UID:GID (`id <admin-user>` on the NAS).

If the error symptom is instead about a fresh directory newly created via DSM File Station (rather than via the init script or `mkdir`), DSM may have applied a restrictive ACL. Clear it:

```bash
sudo synoacltool -del /volume1/docker/observability/<service>/data
sudo chown -R 1026:100 /volume1/docker/observability/<service>/data
# Re-running scripts/init-nas-paths.sh does both.
```

### cAdvisor fails to start with capability error

**Symptom:** cAdvisor logs show an error about `SYS_ADMIN` capability or `/dev/kmsg` access. Container exits quickly.

**Cause:** DSM 7.3 may reject the `cap_add: [SYS_ADMIN]` + `devices: [/dev/kmsg]` combination for unprivileged containers in some configurations.

**Recovery:** Fall back to `privileged: true` for cAdvisor in `docker-compose.yml`, but only if this specific failure is observed. Quote the exact DSM-side error in the PR description as the justification — we prefer the narrower grant by default, and `privileged: true` should be a documented exception, not a silent upgrade.

```yaml
  cadvisor:
    # ... existing config ...
    # Replace devices + cap_add with:
    privileged: true
```

### Port collision

**Symptom:** Portainer reports a service failed to start with "address already in use" or similar.

**Recovery:** On the NAS, find the culprit:

```bash
sudo ss -tlnp | grep <port>
```

If another DSM service owns the port, either reconfigure that service via the DSM UI or reassign our service to a different port within its reserved range (see `docs/ports.md`). Either way, update `docs/ports.md` in the same PR.

### Grafana datasource unhealthy

**Symptom:** In Grafana, the `prometheus` datasource shows as unhealthy. Dashboards display "no data."

**Diagnosis:** From inside the Grafana container, check that Prometheus is reachable over localhost (remember we're using host networking):

```bash
docker exec -it grafana wget -q -O- http://localhost:9090/-/healthy
```

If this succeeds, the datasource config is wrong (check `docker/grafana/provisioning/datasources/datasources.yaml`). If it fails, Prometheus isn't running or isn't bound to `:9090` — investigate via `docker logs prometheus`.

### node_exporter deploy fails with mount propagation error

**Symptom:** Portainer (or `docker compose up`) fails with:
```
path / is mounted on / but it is not a shared or slave mount
```

**Cause:** The node_exporter service mounts `/` into the container. If that volume specifies `rslave` propagation (the upstream-recommended recipe), Docker refuses unless the host's `/` is already mounted as `shared` or `slave`. DSM 7.3 mounts `/` as `private` by default.

**Recovery:** Already applied in this repo — `docker-compose.yml` uses plain `ro` for the `/:/host/root` mount (no `rslave`). Mount topology on the NAS is stable after boot, so propagation isn't needed. If you ever re-introduce `rslave` from an upstream example, this error returns.

### cAdvisor fails with "Bind mount failed: /dev/disk does not exist"

**Symptom:** Deploy fails with:
```
Bind mount failed: '/dev/disk' does not exist
```

**Cause:** DSM 7.3 doesn't populate `/dev/disk/` by default. Upstream cAdvisor recipes mount it to label disk I/O metrics with physical-device names.

**Recovery:** Already applied in this repo — the `/dev/disk` mount has been dropped from cAdvisor's volumes. Per-container I/O metrics still work; we just don't get device-label fidelity on them. Host-level disk telemetry (SMART, per-drive temperature, per-volume usage) comes from SNMP in Feature 002 instead.

### cAdvisor fails with "Bind mount failed: /var/lib/docker does not exist"

**Symptom:** Deploy fails with:
```
Bind mount failed: '/var/lib/docker' does not exist
```

**Cause:** DSM's Container Manager stores Docker state at `/volume1/@docker`, not the standard Linux `/var/lib/docker`. Most upstream cAdvisor recipes assume the default path.

**Recovery:** Already applied in this repo — `docker-compose.yml` mounts `/volume1/@docker/:/var/lib/docker:ro` for cAdvisor. If you're forking this onto a different NAS and seeing this error, verify your Docker root dir:
```bash
docker info | grep "Docker Root Dir"
```
and update the host side of cAdvisor's `/var/lib/docker` mount in `docker-compose.yml` to match.

### Grafana Dashboards UI is empty even though the stack is healthy

**Symptom:** Grafana login works, the Prometheus datasource is provisioned and healthy, the CI-published image is pulled correctly, but the **Dashboards** page shows nothing. No `Stack Health` dashboard anywhere.

**Cause:** The image baked dashboard JSON into a container path that compose bind-mounts for persistent state. A bind mount **overlays** whatever the image baked at that path — so the dashboards get hidden by the (empty) host directory at runtime. Classic Docker gotcha when mixing "config baked into the image" with "state persisted via bind mount."

**Recovery:** Already applied in this repo. Dashboards live under `/etc/grafana/dashboards/` (not bind-mounted), while `/var/lib/grafana/` is reserved for Grafana's sqlite DB + plugins + renders (which genuinely need to persist). If you're forking and adding a new baked asset, keep config under `/etc/` and state under `/var/lib/` — never bake into a path that's a child of a bind-mount target.

Debug check when "my baked config isn't being picked up" hits a future service: `docker exec <container> ls <expected-path>` shows whatever the bind mount is serving (typically empty on first boot), not what the image baked. Confirms the mask.

### Grafana image pull fails as unauthenticated

**Symptom:** Portainer fails to pull `ghcr.io/mstellaris/nas-observability/grafana:...` with an "unauthorized" error.

**Cause:** The GHCR package visibility was not set to public after the first CI publish.

**Recovery:** Flip the package to public via the GitHub UI (Packages → this image → Settings → Change visibility → Public). Alternatively, configure the NAS's Docker daemon with GHCR credentials, but for a single-operator homelab, public is simpler.
