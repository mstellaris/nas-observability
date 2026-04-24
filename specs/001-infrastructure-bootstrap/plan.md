# Implementation Plan: Infrastructure Bootstrap

**Feature Branch:** `001-infrastructure-bootstrap`
**Spec:** [`spec.md`](./spec.md)
**Status:** Draft
**Last updated:** 2026-04-23

---

## Technical Context

This plan is an infrastructure-as-code feature. There is no application code — the deliverables are Docker Compose, container configuration, a custom Grafana image, a GitHub Actions workflow, and operator documentation. Everything references the ratified [`constitution.md`](../../.specify/memory/constitution.md) as the design authority.

**Runtime:** Docker 24+ on DSM 7.3 (Synology Container Manager), Compose v2 schema
**Hardware:** Synology DS224+ (Intel Celeron J4125, 2–6 GB RAM)
**Networking:** `network_mode: host` for all services (Constitution Principle III)
**Images:**
- `prom/prometheus:v3.1.0` — upstream, Docker Hub
- `gcr.io/cadvisor/cadvisor:v0.49.1` — upstream, Google Container Registry
- `prom/node-exporter:v1.8.2` — upstream, Docker Hub
- Custom Grafana image: `ghcr.io/<github-owner>/nas-observability/grafana:vX.Y.Z` (base `grafana/grafana:11.4.0-oss`)

`<github-owner>` in image references throughout this document is a placeholder for the actual GitHub username or organization under which this repo lives. The CI workflow resolves it dynamically via `${{ github.repository_owner }}`; the prose uses the placeholder to stay environment-agnostic.

Image versions above are the reference choices for the first build; they are pinned in `docker-compose.yml` by exact tag per Constitution Principle I. Moving to newer upstream versions is a PR-gated decision, not automatic.

**CI/CD:** GitHub Actions, GHCR for custom image publishing
**Secrets:** `.env` at repo root, gitignored (Constitution §Secrets). Populated on the NAS via Portainer's stack environment variables.
**Bind mounts:** `/volume1/docker/observability/` on the NAS
**Documentation:** `docs/setup.md`, `docs/deploy.md`, `docs/ports.md` (authoritative port allocation table)

---

## Constitution Check

This plan is measured against each principle of [`constitution.md`](../../.specify/memory/constitution.md) v1.0.0.

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Upstream-First, Thin Customization | ✅ Pass | Three of four services use unmodified upstream images at pinned versions. Grafana is the sole custom image; customization is limited to baking in datasource provisioning, dashboard provider config, and one dashboard JSON — no upstream patches, no plugin injection. |
| II. Declarative Configuration as Source of Truth | ✅ Pass | `docker-compose.yml`, `config/prometheus/prometheus.yml`, `docker/grafana/` provisioning tree, `.env.example`, and `scripts/init-nas-paths.sh` make every step reproducible. The one manual NAS step (SNMP enablement) is explicitly out of scope for F001. |
| III. Host Networking by Default | ✅ Pass | All four services declare `network_mode: host`. Scrape targets use `localhost:<port>`. `docs/ports.md` is introduced as the authoritative port allocation table. |
| IV. Resource Discipline | ✅ Pass | Per-service `mem_limit` sums to 560 MB; 40 MB reserved for Feature 002. Prometheus retention enforced via `--storage.tsdb.retention.time=30d` and `--storage.tsdb.retention.size=5GB`. |
| V. Silent-by-Default Alerting | N/A | Feature 001 ships no alert rules. Alertmanager and delivery configuration are explicitly out of scope (deferred to a dedicated alerting feature). |

**Violations:** none.

---

## Project Structure

### Files introduced by this feature

```
nas-observability/
├── docker-compose.yml
├── .env.example
├── .gitignore                           # updated: add .env, .claude/, data dirs
├── VERSION                              # single line, semver, read by CI for image tags
│
├── config/
│   └── prometheus/
│       └── prometheus.yml               # scrape config, retention is on the CLI
│
├── docker/
│   └── grafana/
│       ├── Dockerfile
│       ├── provisioning/
│       │   ├── datasources/
│       │   │   └── datasources.yaml
│       │   └── dashboards/
│       │       └── dashboards.yaml      # provider config pointing at /var/lib/grafana/dashboards
│       ├── dashboards/
│       │   └── stack-health.json        # baked-in meta-health dashboard (Spec D3)
│       └── scripts/
│           └── inject-build-metadata.sh # substitutes GIT_SHA + VERSION into stack-health.json at build time
│
├── scripts/
│   └── init-nas-paths.sh                # one-shot NAS-side init: mkdir, chown, synoacltool
│
├── docs/
│   ├── setup.md                         # DSM prerequisites + bind-mount init + ACL troubleshooting
│   ├── deploy.md                        # Portainer redeploy flow + rollback
│   └── ports.md                         # authoritative port allocation table
│
├── .github/
│   ├── workflows/
│   │   └── build-grafana-image.yml      # build + push on push-to-main (nightly added in F003)
│   └── pull_request_template.md         # embeds compliance checklist
│
└── specs/
    └── 001-infrastructure-bootstrap/
        ├── spec.md
        ├── plan.md                      # this file
        └── tasks.md                     # generated next from this plan
```

### What this feature does NOT introduce

- `config/snmp_exporter/`, `config/alertmanager/`, any SMTP configuration, any Synology MIBs, any application-specific dashboards. All deferred per spec Out of Scope.
- A reverse proxy (Caddy) or any external-access hardening. Grafana is reachable directly on port 3030 on the home LAN for F001.
- `scripts/check-budget.sh` or any automated compliance-check script. Compliance is enforced via the PR template and reviewer attention in F001; an automated check can be added later if we find reviewers missing violations.

---

## Service Configuration

### Prometheus

**Image:** `prom/prometheus:v3.1.0`
**Host port:** 9090
**Memory limit:** 280 MB
**Command-line flags:**
```
--config.file=/etc/prometheus/prometheus.yml
--storage.tsdb.path=/prometheus
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=5GB
--web.enable-lifecycle
--web.listen-address=:9090
```
`--web.enable-lifecycle` permits runtime reload of `prometheus.yml` via `POST /-/reload`; useful for adding scrape targets in later features without restarting the container.

**Volumes:**
- `./config/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro`
- `/volume1/docker/observability/prometheus/data:/prometheus`

**Scrape config** (`config/prometheus/prometheus.yml`):
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node_exporter
    static_configs:
      - targets: ['localhost:9100']

  - job_name: cadvisor
    scrape_interval: 30s
    static_configs:
      - targets: ['localhost:8080']
```

**Why 15s global, 30s cAdvisor:** Prometheus self-scrape and node_exporter are cheap (small exposition, stable cardinality) and benefit from 15s granularity for real-time dashboard responsiveness. cAdvisor's exposition is bulkier (one metric set per container, growing as we add consumers) and 30s halves the scrape-path memory pressure — a direct contributor to staying under cAdvisor's 90 MB budget.

### Grafana

**Image:** `ghcr.io/<github-owner>/nas-observability/grafana:vX.Y.Z` (custom, see §Custom Grafana Image)
**Host port:** 3030
**Memory limit:** 140 MB
**Environment:**
```
GF_SERVER_HTTP_PORT=3030
GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_USERS_ALLOW_SIGN_UP=false
```

**Volumes:**
- `/volume1/docker/observability/grafana/data:/var/lib/grafana`

No provisioning volume — provisioning is baked into the image, not mounted. This is deliberate: it means the Grafana image at tag `vX.Y.Z` is a complete, versioned artifact, not a container whose behavior depends on a correctly-mounted host directory.

### cAdvisor

**Image:** `gcr.io/cadvisor/cadvisor:v0.49.1`
**Host port:** 8080
**Memory limit:** 90 MB
**Command-line flags:**
```
--port=8080
--storage_duration=1m
--housekeeping_interval=30s
--docker_only=true
--disable_metrics=percpu,sched,tcp,udp,accelerator,hugetlb,referenced_memory,cpu_topology,resctrl
```
**Why these flags (all required, not optional — Spec D2):**
- `--storage_duration=1m` (down from 2m default): halves in-memory retention of recent samples, the largest single memory cost at rest.
- `--housekeeping_interval=30s` (up from 1s default): the default is absurdly aggressive and wastes CPU + memory for a scrape target read every 30s anyway.
- `--docker_only=true`: ignore non-Docker cgroups (DSM system services), which we don't need metrics for.
- `--disable_metrics=...`: disables high-cardinality or irrelevant collectors. Kept enabled: `cpu`, `memory`, `network`, `diskIO`, `process`, `app`. These cover everything Principal Feature 003+ app dashboards will query.

**Volumes (read-only host mounts, adjusted from the upstream recipe):**
- `/:/rootfs:ro`
- `/var/run:/var/run:ro`
- `/sys:/sys:ro`
- `/volume1/@docker/:/var/lib/docker:ro` — DSM-specific host path

The upstream recipe mounts `/var/lib/docker` from the host, which is where the Docker daemon stores state on standard Linux distributions. DSM's Container Manager stores Docker state at `/volume1/@docker` instead; `/var/lib/docker` doesn't exist on the host. Verify the path on any given NAS with `docker info | grep "Docker Root Dir"`. The in-container target stays `/var/lib/docker` because that's what cAdvisor expects — only the host source changes.

The upstream recipe also mounts `/dev/disk` (used to label disk I/O metrics with physical-device names), but DSM 7.3 doesn't populate `/dev/disk/`. Per-container disk I/O metrics still work without it — we just lose device-label fidelity on those metrics. Host-level disk telemetry (SMART, per-drive temperature, per-volume usage) lives under the SNMP exporter in Feature 002, not cAdvisor.

**Devices & capabilities (narrower than `privileged: true`):**
```yaml
devices:
  - /dev/kmsg:/dev/kmsg
cap_add:
  - SYS_ADMIN
```
`/dev/kmsg` is required for some kernel metrics on recent cAdvisor versions; `SYS_ADMIN` is the minimum capability cAdvisor needs to read cgroup data across all container namespaces. This combination is strictly narrower than `privileged: true` and should be preferred.

**Fallback:** If DSM 7.3 rejects this combination at deploy time (Phase 8 is the first opportunity to find out), fall back to `privileged: true` with a written justification in `docs/setup.md` naming the specific DSM-side error observed. Never silently upgrade to `privileged: true` without that justification — the narrower grant is a Constitution Principle III-adjacent discipline (smallest sufficient privilege).

### node_exporter

**Image:** `prom/node-exporter:v1.8.2`
**Host port:** 9100
**Memory limit:** 50 MB
**Command-line flags:**
```
--path.rootfs=/host/root
--path.procfs=/host/proc
--path.sysfs=/host/sys
--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
```

**Volumes (read-only host mounts, adjusted from the upstream recipe):**
- `/proc:/host/proc:ro`
- `/sys:/host/sys:ro`
- `/:/host/root:ro`

The upstream recipe uses `ro,rslave` on the `/` mount to propagate post-start mount changes into the container. DSM 7.3 mounts `/` as private (the Linux default), which Docker refuses to combine with rslave propagation — the deploy fails with "path / is mounted on / but it is not a shared or slave mount". On the NAS, mount topology is stable after boot (`/volume1`, etc. are mounted during DSM init, long before Docker), so plain `ro` captures accurate filesystem metrics without the propagation flag.

---

## Custom Grafana Image

### Dockerfile design

```dockerfile
ARG GRAFANA_VERSION=11.4.0
FROM grafana/grafana:${GRAFANA_VERSION}-oss

ARG GIT_SHA=dev
ARG VERSION=0.0.0

COPY provisioning/datasources/datasources.yaml /etc/grafana/provisioning/datasources/datasources.yaml
COPY provisioning/dashboards/dashboards.yaml /etc/grafana/provisioning/dashboards/dashboards.yaml
COPY dashboards/ /var/lib/grafana/dashboards/

COPY scripts/inject-build-metadata.sh /tmp/inject-build-metadata.sh
RUN /tmp/inject-build-metadata.sh "${VERSION}" "${GIT_SHA}" /var/lib/grafana/dashboards/stack-health.json \
 && rm /tmp/inject-build-metadata.sh

LABEL org.opencontainers.image.source="https://github.com/<github-owner>/nas-observability"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
```

**Why this shape:**
- Single-stage: no compilation needed; we're only copying files and doing a trivial in-place substitution.
- Layer order (datasources → dashboards config → dashboards directory → build-metadata substitution): puts stable files first, mutable files last, so rebuilds driven by dashboard edits don't re-invalidate the provisioning config layers.
- Build args for `VERSION` and `GIT_SHA`: injected by CI, substituted into the `Stack Health` dashboard JSON via `inject-build-metadata.sh` (trivial `sed` replacement on placeholder tokens like `{{VERSION}}` and `{{GIT_SHA}}`). This is how the image tag becomes visible inside Grafana at runtime (Spec FR-8).
- OCI labels: let `docker inspect` and GHCR's UI show the source repo, version, and revision.

### Provisioning files

`datasources/datasources.yaml`:
```yaml
apiVersion: 1
datasources:
  - name: prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
```
`editable: false` is deliberate: this datasource is a repo-owned artifact. Nobody should be clicking in the Grafana UI to edit it. Explicit `uid: prometheus` is set so dashboard `datasource.uid` references are deterministic across builds (Grafana auto-generates a UID when one isn't specified, which can differ between environments).

`dashboards/dashboards.yaml`:
```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
```
`allowUiUpdates: false`: dashboard JSON in the image is the source of truth; UI edits are reviewed as repo changes, not runtime state.

### `Stack Health` dashboard composition

A single dashboard, 3 rows, ~6 panels. Concrete layout:

| Row | Panel | Type | Query |
|-----|-------|------|-------|
| 1 | Prometheus UP | Stat | `up{job="prometheus"}` |
| 1 | node_exporter UP | Stat | `up{job="node_exporter"}` |
| 1 | cAdvisor UP | Stat | `up{job="cadvisor"}` |
| 1 | TSDB head series | Stat | `prometheus_tsdb_head_series` |
| 2 | Scrape duration by target | Time series | `scrape_duration_seconds` |
| 3 | Build metadata | Text panel | Markdown: `Image version: {{VERSION}} ({{GIT_SHA}})` — substituted at image build time |

Dashboard-level settings:
- Default time range: last 6 hours
- Auto-refresh: 30s
- Tags: `stack-health`, `meta`

Keeping it to six panels deliberately: this is a meta-health view, not a showcase. Feature 002's NAS dashboards and Feature 003+'s app dashboards will carry the depth.

---

## CI/CD: GitHub Actions

### Workflow: `build-grafana-image.yml`

**Triggers:**
```yaml
on:
  push:
    branches: [main]
    paths:
      - 'docker/grafana/**'
      - 'VERSION'
      - '.github/workflows/build-grafana-image.yml'
  workflow_dispatch:
```

**No nightly schedule in F001.** The constitution describes a nightly build as part of the consumer-dashboard propagation mechanism, but F001 has no consumer dashboards for it to propagate. Wiring the schedule now would produce 365 identical images per year in GHCR until Feature 003 actually adds consumer dashboards to the build context. The `schedule:` trigger ships with F003, at the same time as the Mneme-dashboards checkout step it exists to serve.

**Why path filters on push:** avoid rebuilding when only the README or unrelated docs change.

**Job shape:**
```yaml
jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - id: meta
        run: |
          VERSION=$(cat VERSION)
          SHA=$(git rev-parse --short HEAD)
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "sha=${SHA}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: docker/grafana
          push: true
          build-args: |
            VERSION=${{ steps.meta.outputs.version }}
            GIT_SHA=${{ steps.meta.outputs.sha }}
          tags: |
            ghcr.io/${{ github.repository_owner }}/nas-observability/grafana:v${{ steps.meta.outputs.version }}
            ghcr.io/${{ github.repository_owner }}/nas-observability/grafana:sha-${{ steps.meta.outputs.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Tag policy:**
- `v<semver>` from `VERSION` file — stable, human-referable tag. Bumping `VERSION` and merging to `main` publishes a new semver-tagged image.
- `sha-<7>` for every build — lets Portainer pin an exact commit without depending on `VERSION` being accurate.
- Not published: `latest` (forbidden per Constitution Principle I "no `:latest`"), nor `main` (redundant with sha tag).

**Image name convention:** `ghcr.io/<owner>/nas-observability/grafana`. Keeping `/grafana` as a suffix leaves room for `/snmp-exporter-with-mibs` or similar if Feature 002 needs a custom image too.

---

## Operator Tooling

### Bind-mount init script

`scripts/init-nas-paths.sh`:
```bash
#!/bin/bash
set -euo pipefail

BASE=/volume1/docker/observability

for sub in prometheus/data grafana/data; do
  sudo mkdir -p "${BASE}/${sub}"
  sudo synoacltool -del "${BASE}/${sub}" || true
done

sudo chown -R 65534:65534 "${BASE}/prometheus/data"     # nobody:nobody (Prometheus container user)
sudo chown -R 472:472     "${BASE}/grafana/data"         # grafana:grafana (Grafana container user)

echo "NAS paths initialized under ${BASE}. Deploy the stack via Portainer next."
```

Runs via SSH on the NAS once, before the first Portainer deploy. The `synoacltool -del` call (with `|| true` because it fails harmlessly if no ACL is set) is the critical line — the lesson from prior Docker deploys on this NAS is that `chown` alone is not enough (see `docs/setup.md` troubleshooting).

### `docs/setup.md` — outline

- **Prerequisites**: DSM 7.3, Container Manager installed, Portainer installed, SSH enabled, admin user in the `docker` group.
- **One-time NAS init**: clone repo on NAS or copy `scripts/init-nas-paths.sh`, run it over SSH. Expected output shown.
- **`.env` population**: copy `.env.example` to `.env`, set a real `GRAFANA_ADMIN_PASSWORD`. Do NOT commit.
- **First deploy via Portainer**: point stack at repo's `docker-compose.yml`, paste `.env` contents into Portainer's environment variables field, deploy.
- **Verification**: visit `http://<nas-ip>:9090/targets` (all UP), visit `http://<nas-ip>:3030` (Grafana login), confirm `Stack Health` dashboard renders.
- **Troubleshooting — ACL-related restart loops**: explicit recovery runbook. If any container is in a restart loop and `docker logs` shows permission-denied writes to a bind mount while `ls -l` shows correct ownership, the cause is a residual DSM ACL shadowing POSIX permissions. Recovery:
  ```
  sudo synoacltool -del /volume1/docker/observability/<service>/data
  sudo chown -R <uid>:<gid> /volume1/docker/observability/<service>/data
  # then restart the container
  ```
  with the specific UIDs for each service (65534:65534 for Prometheus, 472:472 for Grafana) spelled out. This is the primary recurring failure mode on this NAS from prior Docker deployments, and deserves specific rather than generic troubleshooting.
- **Troubleshooting — port collision**: `ss -tlnp | grep <port>` on the NAS to find the culprit; reassign per `docs/ports.md`.
- **Troubleshooting — Grafana datasource unhealthy**: check `localhost:9090` reachability from inside the Grafana container (`docker exec -it grafana wget -q -O- http://localhost:9090/-/healthy`).

### `docs/deploy.md` — outline

- **Redeploy for updates**: in Portainer, pull latest image for the Grafana container and redeploy the stack. The `sha-<short>` tag is pinned in `docker-compose.yml`, so bumping it is a repo PR followed by stack redeploy.
- **Rollback**: change the Grafana tag in `docker-compose.yml` back to the previous `sha-<short>` or `v<prev-semver>`, commit, redeploy.
- **Adding a new service**: reference the compliance checklist below. No service is added without all five points satisfied.

### `docs/ports.md` — content

Adopts the spec's D1 table verbatim. Written as the authoritative reference, not a duplicate of the spec.

### `.github/pull_request_template.md` — compliance checklist

```markdown
## Compliance Checklist

Every PR that adds or modifies a service in the stack MUST confirm:

- [ ] **Pinned image version** — no `:latest`, no floating tags.
- [ ] **Explicit `mem_limit`** — declared in `docker-compose.yml`.
- [ ] **Total RAM budget ≤ 600 MB** — sum of all `mem_limit` values does not exceed the constitutional cap. Include current arithmetic in the PR description.
- [ ] **Port declared in `docs/ports.md`** — any host port this service binds is listed in the authoritative port allocation table, within an existing reserved range.
- [ ] **Bind mount documented** — if the service persists state, the host path is declared in `docker-compose.yml` AND in `docs/setup.md` with correct UID/GID guidance.

(Remove or strike through this section for doc-only or CI-only PRs that don't touch services.)
```

No automated checker in F001; reviewer enforces. If we find PRs slipping past in practice, add `scripts/check-budget.sh` later as a one-liner CI job.

### `.env.example` — F001 content

```
# Grafana admin credentials (override before first deploy)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=changeme
```

Later features will grow this: SMTP credentials (alerting feature), SNMPv3 credentials (Feature 002 if SNMPv3 is used), per-app datasource credentials (Feature 003+). For F001, two keys is the full set.

### `.gitignore` — additions

```
.env
/data/
.claude/
```

(`/data/` is defensive in case someone runs `docker compose up` in a local dev context that creates bind-mount targets under the repo root.)

---

## Implementation Deviations

Documented post-hoc: the plan above describes the original design; the list below captures what actually shipped differently and why. Each deviation was discovered during Phase 8 (first NAS deploy) and fixed in-flight. The honest treatment: preserve what the plan prescribed, then explain the gap.

- **Grafana base image**: plan referenced `grafana/grafana:11.4.0-oss`; that tag doesn't exist on Docker Hub. Real OSS-only tag is `grafana/grafana-oss:11.4.0` (separate repo). Dockerfile uses the correct tag.
- **Grafana build-time user**: plan's Dockerfile sketch didn't specify `USER`; image default is `grafana` (non-root), which fails `sed -i` during dashboard substitution because `COPY` leaves files root-owned. Dockerfile switches to `USER root` for build steps and restores `USER grafana` at the end, with `chown -R grafana:root` on the provisioning and dashboards paths.
- **Datasource `uid`**: plan's `datasources.yaml` didn't set an explicit `uid`. Grafana auto-generates UIDs when unspecified, which can differ between environments and break dashboards referencing `datasource.uid`. Added `uid: prometheus` for determinism.
- **Prometheus config bind mount**: plan used a relative path (`./config/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro`). Portainer's "Repository" deploy mode clones into its own internal workspace which isn't host-visible, so relative mounts fail to resolve. Fix: place `prometheus.yml` at an absolute host path (`/volume1/docker/observability/prometheus/prometheus.yml`), populated by the init script via `curl` from the repo's raw URL.
- **node_exporter `/` mount propagation**: plan used `ro,rslave` (upstream-recommended). Docker refuses `rslave` unless the source mount is `shared` or `slave`; DSM 7.3 mounts `/` as `private`. Simplified to plain `ro`. Tradeoff: no propagation of post-start mount changes into the container, which is fine on a NAS with stable mount topology.
- **cAdvisor `/var/lib/docker` mount source**: plan used the standard `/var/lib/docker` path. DSM's Container Manager stores Docker state at `/volume1/@docker` (verify per-NAS with `docker info | grep "Docker Root Dir"`). Host source changed; container target (`/var/lib/docker`) stayed the same.
- **cAdvisor `/dev/disk` mount**: plan included `/dev/disk/:/dev/disk:ro` per upstream recipe; DSM 7.3 doesn't populate `/dev/disk/`. Dropped. Loses device-label fidelity on per-container I/O metrics; host-level disk telemetry comes from SNMP (Feature 002) anyway.
- **cAdvisor `--disable_metrics` values**: plan included `accelerator` (GPU monitoring). Removed in cAdvisor v0.49.1 as a disable target. Dropped from the flag value.
- **Service user for Prometheus and Grafana**: plan's implicit assumption was that the image-default users (`nobody:65534` for Prometheus, `grafana:472` for Grafana) would work against the bind-mounted data directories after `chown` to match. Reality: DSM 7.3 blocks writes from low/system UIDs to `/volume1/` paths regardless of POSIX permissions — a DSM security model restriction, not an ACL. Fix: run both services as the DSM admin UID (`1026:100` for `superman:users` on this NAS). `docker-compose.yml` sets `user: "1026:100"` on prometheus and grafana; `scripts/init-nas-paths.sh` chowns bind mounts to match.
- **Bind-mount directory mode on DSM**: `mkdir -p` via shell on DSM creates directories under `/volume1/docker/` with POSIX mode `0000` plus a DSM ACL marker. `chown` alone (even after `synoacltool -del`) leaves mode `0000`, which denies all access regardless of owner. Fix: `scripts/init-nas-paths.sh` now adds an explicit `chmod -R 0755` after chown.
- **cAdvisor port 8080 collision**: plan assumed `8080` was available (per D1's port allocation table). In practice mneme-caddy already owned `:8080` on this NAS. With `network_mode: host`, cAdvisor couldn't bind and crashed with "address already in use." Fix: move cAdvisor to `8081` (within the same reserved range `8080–8099`), update Prometheus scrape target and `docs/ports.md` to match.
- **cAdvisor baked-in healthcheck**: cAdvisor's image HEALTHCHECK hardcodes `wget http://localhost:8080/healthz`. With `--port=8081` + `network_mode: host`, that check hits `mneme-caddy` instead and reports the container unhealthy even though cAdvisor is serving correctly. Fix: override the healthcheck in compose to probe `:8081`.
- **Grafana dashboard path vs. bind mount**: plan's Dockerfile copied dashboards to `/var/lib/grafana/dashboards/` and the dashboard-provider config pointed there. Compose bind-mounts `/volume1/docker/observability/grafana/data:/var/lib/grafana`, which overlays the image's baked content with an empty host directory — baked dashboards were invisible at runtime. Fix: move dashboards to `/etc/grafana/dashboards/` (not bind-mounted), update provisioning `options.path` to match. `/var/lib/grafana` remains the persistent-state mount for Grafana's sqlite + plugins.

Each of these changes has a corresponding commit on `main` with the error message that triggered it. The pattern — upstream Docker recipes assume a standard Linux distro and need adjustment for DSM — will recur in Feature 002+ and should be expected, not treated as a surprise.

---

## Implementation Phases

Decomposed in detail in [`tasks.md`](./tasks.md). High-level shape:

1. **Repo scaffolding** — `VERSION`, `.gitignore` updates, `.env.example`, `config/` and `docker/` directory structure.
2. **Compose skeleton** — four services declared with pinned images, `network_mode: host`, `mem_limit`, `restart: unless-stopped`, no volumes yet.
3. **Service configs** — `prometheus.yml`, cAdvisor flags, node_exporter flags, bind mounts wired.
4. **Custom Grafana image** — Dockerfile, provisioning YAMLs, `Stack Health` dashboard JSON, `inject-build-metadata.sh`.
5. **CI workflow** — `build-grafana-image.yml` with GHCR publishing; dry-run in a PR first, merge once the image lands in GHCR correctly.
6. **NAS init script** — `scripts/init-nas-paths.sh`.
7. **Documentation** — `docs/setup.md` (including the ACL recovery runbook), `docs/deploy.md`, `docs/ports.md`, PR template.
8. **DS224+ cold deploy** — run init script, populate `.env` in Portainer, deploy stack, walk through every acceptance scenario in `spec.md`.
9. **Tuning pass** — observe `docker stats` for 1 hour, confirm all services within `mem_limit`, trim cAdvisor further if over 90 MB (Spec D2 mandates this rather than budget expansion).

Phase 8 is the first end-to-end integration test; expect to find at least one thing wrong (most likely ACL-related). Phase 9 validates NFR-1.

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| cAdvisor exceeds 90 MB even after flag tuning | Medium | Spec D2 pre-commits the response: trim another service rather than expand budget. Concrete fallbacks: drop Grafana to 120 MB (cuts a small amount of plugin headroom), drop node_exporter to 40 MB (still comfortable for scrape load). |
| ACL-related restart loop on first deploy | High | Init script calls `synoacltool -del` preemptively. `docs/setup.md` troubleshooting section documents the specific recovery. Phase 8 expects to hit this at least once. |
| GHCR auth fails in CI (token scopes) | Low | Use `${{ secrets.GITHUB_TOKEN }}` with explicit `packages: write` permission on the job — documented path. If org settings disallow package publishing, we'll see it on the first workflow run and fix by adjusting repo-level package permissions. |
| Upstream Grafana 11.4.0-oss provisioning schema changes | Low | We pin the base image; upgrading Grafana is a deliberate PR. Provisioning schema has been stable for several major versions. |
| Prometheus TSDB corruption from improper shutdown | Medium | `restart: unless-stopped` handles crash recovery. WAL replay on restart is upstream-standard. Bind-mounted TSDB to stable `/volume1` storage (SHR, not ephemeral). |
| Residential upstream pull speed makes cold deploy > 5 minutes | Medium | NFR-2b allows 5 minutes. If we consistently miss, we can pre-pull images via `docker pull` over SSH before the Portainer deploy — document as an optional speedup in `docs/deploy.md` if encountered. |
| DSM 7.3 rejects cAdvisor's `SYS_ADMIN` + `/dev/kmsg` device combination | Low | Fall back to `privileged: true` with written justification in `docs/setup.md`. Phase 8 is the first opportunity to surface this; all other deployment risks assume this resolves cleanly. |

---

## Dependencies

Feature 001 has no dependencies on other features in this repo — it is the foundation. External dependencies:

- Synology DS224+ with DSM 7.3, Container Manager, and Portainer already installed.
- SSH access to the NAS enabled for the one-time bind-mount init run.
- A GitHub repository and a GHCR namespace under the same account/org with packages enabled.
- Home LAN reachability of the NAS (no Tailscale, no VPN requirement — Grafana is reachable on local IP for F001; external access is a later feature).

Downstream features depend on F001:
- **Feature 002** (NAS-specific scraping) adds SNMP exporter to the compose file, consumes the reserved 40 MB, adds NAS dashboards to the Grafana image build. The bind-mount init script, port allocation table, CI workflow, and compliance checklist all inherit from F001 unchanged.
- **Feature 003+** (application scraping) adds each consumer's `localhost:<port>` to `prometheus.yml` and its repo's `ops/dashboards/` directory to the Grafana image build via the CI sync step the constitution describes. No F001 infrastructure needs to change.
