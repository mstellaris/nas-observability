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
  /volume1/docker/observability/grafana/data  (owner 472:472)
  /volume1/docker/observability/prometheus/data  (owner 65534:65534)
  /volume1/docker/observability/prometheus/prometheus.yml  (owner 65534:65534, mode 644)

NAS paths initialized under /volume1/docker/observability. Populate GRAFANA_ADMIN_USER and
GRAFANA_ADMIN_PASSWORD in Portainer's stack environment variables, then deploy the stack from
docker-compose.yml.
```

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

### Container restart loop — ACL related (the common case)

**Symptom:** One or more containers (typically Prometheus or Grafana) keep restarting. `docker logs <container>` shows permission-denied errors on a bind-mounted path. But `ls -ln /volume1/docker/observability/<service>/data` shows the correct UID.

**Cause:** DSM's ACLs are shadowing the POSIX permissions. `chown` alone is not sufficient on DSM — Synology layers its own ACLs on top of the standard Linux permission bits, and a stale ACL will silently block writes.

**Recovery:**

```bash
# On the NAS, over SSH:
sudo synoacltool -del /volume1/docker/observability/prometheus/data
sudo chown -R 65534:65534 /volume1/docker/observability/prometheus/data

# For Grafana:
sudo synoacltool -del /volume1/docker/observability/grafana/data
sudo chown -R 472:472 /volume1/docker/observability/grafana/data

# Then restart the stuck container via Portainer (or `docker restart <name>`).
```

`scripts/init-nas-paths.sh` already does the `synoacltool -del` preemptively, so hitting this usually means someone recreated the directory through DSM File Station (which re-applies ACLs) or the script wasn't run. Re-running the init script is also a valid recovery.

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

### Grafana image pull fails as unauthenticated

**Symptom:** Portainer fails to pull `ghcr.io/mstellaris/nas-observability/grafana:...` with an "unauthorized" error.

**Cause:** The GHCR package visibility was not set to public after the first CI publish.

**Recovery:** Flip the package to public via the GitHub UI (Packages → this image → Settings → Change visibility → Public). Alternatively, configure the NAS's Docker daemon with GHCR credentials, but for a single-operator homelab, public is simpler.
