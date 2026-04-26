#!/bin/bash
# Removes the four export-environment keys Grafana injects on every JSON
# export (__inputs, __elements, __requires, iteration). Keeps committed
# dashboard diffs limited to real content (panels, queries, layout).
#
# Usage: ./scripts/strip-grafana-export-noise.sh path/to/dashboard.json
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <dashboard.json>" >&2
  exit 2
fi

target="$1"

if [ ! -f "$target" ]; then
  echo "ERROR: file not found: $target" >&2
  exit 1
fi

jq 'del(.__inputs, .__elements, .__requires, .iteration)' "$target" > "$target.tmp"
mv "$target.tmp" "$target"
echo "Stripped export-environment keys from $target"
