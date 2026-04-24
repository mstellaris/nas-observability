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

# Bind mounts are chowned to the DSM admin UID:GID (1026:100 for the
# "superman:users" admin user on this NAS). DSM 7.3 blocks writes from
# low/system UIDs (the image defaults nobody/65534 for Prometheus and
# grafana/472 for Grafana) to /volume1 paths, so running containers as
# their image-default user against a /volume1 bind mount fails with
# "permission denied". Admin UID sidesteps it; docker-compose.yml's
# `user: "1026:100"` directives match these chowns.
#
# If you fork this onto a NAS where the admin UID:GID differs, change
# the value here AND in docker-compose.yml for the prometheus and
# grafana services.
OWNER=1026:100

declare -a BIND_PATHS=(
  "prometheus/data"
  "grafana/data"
  "snmp_exporter"
)

for sub in "${BIND_PATHS[@]}"; do
  path="${BASE}/${sub}"
  mkdir -p "${path}"
  synoacltool -del "${path}" &>/dev/null || true
  chown -R "${OWNER}" "${path}"
  # DSM creates directories under /volume1/docker/ with POSIX mode 0000
  # and an ACL, so even after chown the owner has no POSIX perms and the
  # ACL may not grant UID 1026 access. Explicit chmod restores POSIX
  # rwxr-xr-x, which is enough for the container to write.
  chmod -R 0755 "${path}"
  echo "  ${path}  (owner ${OWNER}, mode 0755)"
done

# Fetch prometheus.yml into the host path the stack bind-mounts.
PROM_CONFIG="${BASE}/prometheus/prometheus.yml"
curl -fsSL -o "${PROM_CONFIG}" "${REPO_RAW}/config/prometheus/prometheus.yml"
synoacltool -del "${PROM_CONFIG}" &>/dev/null || true
chown "${OWNER}" "${PROM_CONFIG}"
chmod 644 "${PROM_CONFIG}"
echo "  ${PROM_CONFIG}  (owner ${OWNER}, mode 644)"

# SNMP exporter: verify .community exists (one-time operator action per
# docs/snmp-setup.md §Step 3), then render snmp.yml.template via sed
# (DSM doesn't ship envsubst; sed handles ${VAR} token substitution
# with $ as literal when followed by {). If .community is missing,
# emit an inline recovery snippet so the operator can fix it from the
# error output without bouncing to the doc.
COMMUNITY_FILE="${BASE}/snmp_exporter/.community"
SNMP_CONFIG="${BASE}/snmp_exporter/snmp.yml"

if [ ! -s "${COMMUNITY_FILE}" ]; then
  cat >&2 <<EOF

ERROR: SNMP exporter config cannot be rendered —
  ${COMMUNITY_FILE}
is missing or empty.

To fix (one-time, per NAS):
  sudo mkdir -p ${BASE}/snmp_exporter
  sudo bash -c 'echo "<your-community-string>" > ${COMMUNITY_FILE}'
  sudo chmod 600 ${COMMUNITY_FILE}
  sudo chown ${OWNER} ${COMMUNITY_FILE}

Then re-run this script. Full context: docs/snmp-setup.md §Step 3.
EOF
  exit 1
fi

# Render snmp.yml from the committed template.
SNMP_TEMPLATE_TMP=$(mktemp)
curl -fsSL -o "${SNMP_TEMPLATE_TMP}" "${REPO_RAW}/config/snmp_exporter/snmp.yml.template"
community=$(cat "${COMMUNITY_FILE}")
sed 's|${SYNOLOGY_SNMP_COMMUNITY}|'"${community}"'|g' "${SNMP_TEMPLATE_TMP}" > "${SNMP_CONFIG}"
rm -f "${SNMP_TEMPLATE_TMP}"
unset community

synoacltool -del "${SNMP_CONFIG}" &>/dev/null || true
chown "${OWNER}" "${SNMP_CONFIG}"
chmod 644 "${SNMP_CONFIG}"
echo "  ${SNMP_CONFIG}  (owner ${OWNER}, mode 644)"

echo
echo "NAS paths initialized under ${BASE}. Populate GRAFANA_ADMIN_USER and"
echo "GRAFANA_ADMIN_PASSWORD in Portainer's stack environment variables, then"
echo "deploy the stack from docker-compose.yml."
