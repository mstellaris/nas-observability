#!/bin/bash
# One-time NAS-side initialization for the nas-observability stack.
# Run this over SSH on the DS224+ BEFORE creating the Portainer stack.
#
# Usage:  sudo bash scripts/init-nas-paths.sh
#
# The synoacltool -del step clears DSM's ACLs, which override POSIX
# permissions and are the most common cause of Docker container
# restart loops on Synology. See docs/setup.md troubleshooting.

set -euo pipefail

BASE=/volume1/docker/observability

# Prometheus container runs as nobody:nobody (65534:65534).
# Grafana container runs as grafana (UID 472) — bind mount owned by the
# grafana group for simplicity (upstream image uses GID 0 for OpenShift
# compat; on a single-NAS homelab, matching GID keeps ownership intuitive).
declare -A OWNERS=(
  ["prometheus/data"]="65534:65534"
  ["grafana/data"]="472:472"
)

for sub in "${!OWNERS[@]}"; do
  path="${BASE}/${sub}"
  owner="${OWNERS[$sub]}"

  mkdir -p "${path}"
  synoacltool -del "${path}" 2>/dev/null || true
  chown -R "${owner}" "${path}"

  echo "  ${path}  (owner ${owner})"
done

echo
echo "NAS paths initialized under ${BASE}. Populate .env in Portainer's stack"
echo "environment variables, then deploy the stack from docker-compose.yml."
