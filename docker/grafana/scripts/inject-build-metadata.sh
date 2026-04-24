#!/bin/sh
# Substitutes {{VERSION}} and {{GIT_SHA}} placeholders in a Grafana
# dashboard JSON file at image build time. Runs inside the Grafana
# (Alpine) base image during `docker build`.
set -eu

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <VERSION> <GIT_SHA> <dashboard-json-path>" >&2
  exit 2
fi

VERSION="$1"
GIT_SHA="$2"
DASHBOARD="$3"

if [ ! -f "$DASHBOARD" ]; then
  echo "Dashboard file not found: $DASHBOARD" >&2
  exit 1
fi

sed -i \
  -e "s/{{VERSION}}/${VERSION}/g" \
  -e "s/{{GIT_SHA}}/${GIT_SHA}/g" \
  "$DASHBOARD"
