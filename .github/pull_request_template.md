## Summary

<!-- 1-3 sentences on what changes and why. Reference the feature (F00X) or issue if applicable. -->

## Compliance Checklist

Every PR that adds or modifies a service in the stack MUST confirm:

- [ ] **Pinned image version** — no `:latest`, no floating tags.
- [ ] **Explicit `mem_limit`** — declared in `docker-compose.yml`.
- [ ] **Total RAM within the subsystem cap** — sum of `mem_limit` values stays within the relevant subsystem's cap (metrics ≤ 600 MB, logs/RUM ≤ 500 MB, per Principle IV). Include current arithmetic in the PR description.
- [ ] **Port declared in `docs/ports.md`** — any host port this service binds is listed in the authoritative port allocation table, within an existing reserved range.
- [ ] **Bind mount documented** — if the service persists state, the host path is declared in `docker-compose.yml` AND in `docs/setup.md` with correct UID/GID guidance.

<!-- Remove or strike through this section for doc-only or CI-only PRs that don't touch services. -->

## Budget arithmetic

<!-- If this PR touches mem_limit on any service, show the sum for the affected subsystem. Examples:
     Metrics:   Prometheus 280M + Grafana 140M + cAdvisor 60M + node_exporter 30M + SNMP 40M + postgres 50M = 600M ✓ (≤ 600M)
     Logs/RUM:  Loki 200M + Alloy 250M = 450M ✓ (≤ 500M)
-->

## Constitutional principles invoked

<!-- Cite the principles this PR relies on when making tradeoffs. Example:
     Per Principle IV, cAdvisor's --storage_duration is trimmed to 45s to free memory for SNMP.
     Per Principle I, the SNMP exporter uses upstream prom/snmp-exporter unmodified.
-->

## Test plan

<!-- How was this verified? Local build? Deploy to the NAS? If operational, which acceptance scenarios were walked through? -->
