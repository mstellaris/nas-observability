#!/bin/bash
# nas-observability operator-side diagnostic dump.
#
# Usage:  sudo bash scripts/diagnose.sh
#
# Outputs five sections: container states, recent logs, stats, bind-mount
# ownership, and declared-port in-use checks. Designed to run in under
# 10 seconds on a healthy stack and to give one clear read on a broken
# one. Handles partial-stack states (zero, some, or all services running).
#
# Exit codes:
#   0  all expected services Up and healthy (or not-yet-deployed is OK
#      for services not yet in the current feature's scope)
#   1  at least one expected service is restarting or exited
#   2  can't determine (Docker not available, permission denied, etc.)

set -uo pipefail

readonly BASE=/volume1/docker/observability
readonly SERVICES=(prometheus grafana cadvisor node-exporter snmp-exporter postgres-exporter)

# Declared ports from docs/ports.md, as port:service pairs (parallel-array
# form for bash 3.2 compat — DSM has bash 4 but macOS dev shells may not).
# Kept in sync with that file; if they drift, this section's output is
# the failing proxy.
readonly PORTS_LIST=(
  "3030:grafana"
  "8081:cadvisor"
  "9090:prometheus"
  "9100:node-exporter"
  "9116:snmp-exporter"
  "9187:postgres-exporter"
)

# Bind-mount paths expected under $BASE, with mode/ownership hints. The
# `|bootstrap` suffix marks paths whose absence has a special-case
# actionable message (e.g., "not yet bootstrapped" rather than generic
# "missing").
readonly BIND_PATHS=(
  "prometheus/data"
  "prometheus/prometheus.yml"
  "grafana/data"
  "snmp_exporter/snmp.yml|bootstrap"
  "snmp_exporter/.community|bootstrap"
)

# -----------------------------------------------------------------------
# TTY / color handling

if [ -t 1 ]; then
  readonly C_OK=$'\033[32m'   # green
  readonly C_WARN=$'\033[33m' # yellow
  readonly C_ERR=$'\033[31m'  # red
  readonly C_DIM=$'\033[2m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_OK=""
  readonly C_WARN=""
  readonly C_ERR=""
  readonly C_DIM=""
  readonly C_RESET=""
fi

status_ok()   { printf '%sOK%s'   "$C_OK"   "$C_RESET"; }
status_warn() { printf '%sWARN%s' "$C_WARN" "$C_RESET"; }
status_err()  { printf '%sERR%s'  "$C_ERR"  "$C_RESET"; }

print_header() {
  echo "============================================================"
  echo " nas-observability: diagnose"
  echo "============================================================"
  echo
}

print_section() {
  printf '%s[%d/5] %s%s\n' "$C_DIM" "$1" "$2" "$C_RESET"
}

# Global status tracker. Incremented by per-service checks.
UNHEALTHY_COUNT=0
NOT_DEPLOYED_COUNT=0
BOOTSTRAP_MISSING=()

# -----------------------------------------------------------------------
# Section 1 — container states

section_container_states() {
  print_section 1 "Container states"
  printf '  %-16s %-30s %-30s %s\n' "NAME" "STATE" "IMAGE" "UPTIME"
  for svc in "${SERVICES[@]}"; do
    local fmt='{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}'
    local line
    line=$(docker ps -a --filter "name=^${svc}$" --format "$fmt" 2>/dev/null || true)
    if [ -z "$line" ]; then
      printf '  %-16s %s%s\n' "$svc" "$(status_warn)" " not deployed"
      NOT_DEPLOYED_COUNT=$((NOT_DEPLOYED_COUNT + 1))
      continue
    fi
    local state status image
    IFS='|' read -r _ state status image <<<"$line"
    local state_display
    case "$state" in
      running)
        # Status has "Up 5 minutes (healthy)" or "Up 1h (unhealthy)"; pull
        # the health tail if present.
        if [[ "$status" == *"(healthy)"* ]]; then
          state_display="$(status_ok) running (healthy)"
        elif [[ "$status" == *"(unhealthy)"* ]]; then
          state_display="$(status_err) running (unhealthy)"
          UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
        elif [[ "$status" == *"(health: starting)"* ]]; then
          state_display="$(status_warn) running (health: starting)"
        else
          state_display="$(status_ok) running"
        fi
        ;;
      restarting)
        state_display="$(status_err) restarting"
        UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
        ;;
      exited)
        state_display="$(status_err) exited"
        UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
        ;;
      *)
        state_display="$(status_warn) $state"
        ;;
    esac
    printf '  %-16s %-40s %-30s %s\n' "$svc" "$state_display" "$image" "$status"
  done
  echo
}

# -----------------------------------------------------------------------
# Section 2 — recent logs

section_recent_logs() {
  print_section 2 "Recent logs (last 20 lines per service)"
  for svc in "${SERVICES[@]}"; do
    if ! docker ps -a --filter "name=^${svc}$" --format '{{.Names}}' | grep -q .; then
      printf '  %s--- %s --- (not deployed)%s\n\n' "$C_DIM" "$svc" "$C_RESET"
      continue
    fi
    printf '  %s--- %s ---%s\n' "$C_DIM" "$svc" "$C_RESET"
    docker logs --tail 20 "$svc" 2>&1 | sed 's/^/    /' || echo "    (logs unavailable)"
    echo
  done
}

# -----------------------------------------------------------------------
# Section 3 — memory / CPU snapshot

section_stats() {
  print_section 3 "Memory / CPU snapshot"
  local filter=""
  for svc in "${SERVICES[@]}"; do
    filter="${filter:+$filter }--filter name=^${svc}$"
  done
  # shellcheck disable=SC2086
  docker stats --no-stream $filter --format \
    'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' 2>/dev/null \
    | sed 's/^/  /' || echo "  (docker stats unavailable)"
  echo
  echo "  Budget cap: 600 MiB total (Constitution Principle IV)."
  echo
}

# -----------------------------------------------------------------------
# Section 4 — bind mount ownership

section_bind_mounts() {
  print_section 4 "Bind mount ownership"
  for entry in "${BIND_PATHS[@]}"; do
    local path flags
    IFS='|' read -r path flags <<<"$entry|"  # trailing | so flags is always set
    local full="${BASE}/${path}"
    if [ -e "$full" ]; then
      local info
      info=$(ls -lnd "$full" 2>/dev/null | awk '{printf "%s %s:%s", $1, $3, $4}')
      printf '  %-60s %s  %s\n' "$full" "$info" "$(status_ok)"
    else
      printf '  %-60s %s\n' "$full" "$(status_err) MISSING"
      if [[ "$flags" == *bootstrap* ]]; then
        BOOTSTRAP_MISSING+=("$path")
      fi
    fi
  done

  # Actionable summary for the SNMP exporter bootstrap case per plan §Ops Tooling.
  if [ ${#BOOTSTRAP_MISSING[@]} -gt 0 ]; then
    local has_snmp=0 has_community=0
    for p in "${BOOTSTRAP_MISSING[@]}"; do
      [[ "$p" == "snmp_exporter/snmp.yml" ]] && has_snmp=1
      [[ "$p" == "snmp_exporter/.community" ]] && has_community=1
    done
    if [ "$has_snmp" -eq 1 ] && [ "$has_community" -eq 1 ]; then
      printf '  %s→ SNMP exporter config not rendered — .community missing (see docs/snmp-setup.md §Step 3).%s\n' \
        "$C_WARN" "$C_RESET"
    elif [ "$has_snmp" -eq 1 ]; then
      printf '  %s→ SNMP exporter config not rendered, but .community is present — re-run scripts/init-nas-paths.sh.%s\n' \
        "$C_WARN" "$C_RESET"
    fi
  fi
  echo
}

# -----------------------------------------------------------------------
# Section 5 — port-in-use check

section_ports() {
  print_section 5 "Declared port in-use check"
  # ss -tlnH is iproute2 v5+ for no-header; DSM's older ss may not support
  # it and silently returns empty. Use ss -tln and skip the header line
  # explicitly (portable to both), with netstat as a last-resort fallback.
  local listeners
  listeners=$(ss -tln 2>/dev/null | awk 'NR>1 {print $4}' || true)
  if [ -z "$listeners" ]; then
    listeners=$(netstat -tln 2>/dev/null | awk '/^tcp/ {print $4}' || true)
  fi
  for entry in "${PORTS_LIST[@]}"; do
    local port expected
    IFS=':' read -r port expected <<<"$entry"
    if echo "$listeners" | grep -qE "[:.]${port}\$"; then
      printf '  %-6s %-16s %s\n' "$port" "(expected: $expected)" "$(status_ok) listening"
    else
      printf '  %-6s %-16s %s\n' "$port" "(expected: $expected)" "$(status_warn) not bound"
    fi
  done
  echo
}

# -----------------------------------------------------------------------
# Summary

print_summary() {
  echo "============================================================"
  if [ "$UNHEALTHY_COUNT" -gt 0 ]; then
    printf ' Status: %sDEGRADED%s — %d service(s) unhealthy\n' "$C_ERR" "$C_RESET" "$UNHEALTHY_COUNT"
  elif [ "$NOT_DEPLOYED_COUNT" -eq "${#SERVICES[@]}" ]; then
    printf ' Status: %sNOT DEPLOYED%s — stack has no containers yet\n' "$C_WARN" "$C_RESET"
  elif [ "$NOT_DEPLOYED_COUNT" -gt 0 ]; then
    printf ' Status: %sHEALTHY%s — %d deployed service(s) healthy; %d expected service(s) not deployed (pre-feature or partial install)\n' \
      "$C_OK" "$C_RESET" "$((${#SERVICES[@]} - NOT_DEPLOYED_COUNT))" "$NOT_DEPLOYED_COUNT"
  else
    printf ' Status: %sHEALTHY%s — all %d services running\n' "$C_OK" "$C_RESET" "${#SERVICES[@]}"
  fi
  echo "============================================================"
}

# -----------------------------------------------------------------------
# Main

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not in PATH; cannot run diagnostics." >&2
  exit 2
fi

print_header

# Each section wrapped so one failure doesn't stop the others.
section_container_states || true
section_recent_logs      || true
section_stats            || true
section_bind_mounts      || true
section_ports            || true

print_summary

if [ "$UNHEALTHY_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
