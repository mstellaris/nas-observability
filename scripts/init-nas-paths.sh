#!/bin/bash
# One-time NAS-side initialization for the nas-observability stack.
# Safe to re-run — mkdir -p is idempotent and chown/curl are effectively
# upserts. Re-running also refreshes prometheus.yml from the repo.
#
# Usage:  sudo bash scripts/init-nas-paths.sh
#
# The synoacltool -del step clears DSM's ACLs, which override POSIX
# permissions and are the most common cause of Docker container
# restart loops on Synology. See docs/setup.md troubleshooting.
#
# prometheus.yml is curl'd from the repo's main branch into a host
# path (not mounted relative from the compose's working directory),
# because Portainer's "Repository" deploy mode clones into its own
# internal workspace — relative bind mounts fail to resolve on the
# host. Host-path mounts for config files dodge that entirely.

set -euo pipefail

BASE=/volume1/docker/observability
REPO_RAW=https://raw.githubusercontent.com/mstellaris/nas-observability/main

# Data directories, keyed by container-user UID:GID.
declare -A DATA_DIRS=(
  ["prometheus/data"]="65534:65534"
  ["grafana/data"]="472:472"
)

for sub in "${!DATA_DIRS[@]}"; do
  path="${BASE}/${sub}"
  owner="${DATA_DIRS[$sub]}"

  mkdir -p "${path}"
  synoacltool -del "${path}" 2>/dev/null || true
  chown -R "${owner}" "${path}"

  echo "  ${path}  (owner ${owner})"
done

# Fetch prometheus.yml into the host path the stack bind-mounts.
# Must be readable by UID 65534 (the Prometheus container user).
PROM_CONFIG="${BASE}/prometheus/prometheus.yml"
curl -fsSL -o "${PROM_CONFIG}" "${REPO_RAW}/config/prometheus/prometheus.yml"
synoacltool -del "${PROM_CONFIG}" 2>/dev/null || true
chown 65534:65534 "${PROM_CONFIG}"
chmod 644 "${PROM_CONFIG}"
echo "  ${PROM_CONFIG}  (owner 65534:65534, mode 644)"

echo
echo "NAS paths initialized under ${BASE}. Populate GRAFANA_ADMIN_USER and"
echo "GRAFANA_ADMIN_PASSWORD in Portainer's stack environment variables, then"
echo "deploy the stack from docker-compose.yml."
