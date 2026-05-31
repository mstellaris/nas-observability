# Port Allocation

This is the authoritative port allocation table for the nas-observability stack. **Every PR that adds, moves, or removes a host port MUST update this file in the same change.** PRs that modify a service's port without touching this table are rejected at review.

All services run with `network_mode: host` (Constitution Principle III), so every port listed here is bound directly on the DS224+'s host IP.

## Reserved ranges

Adding a new service picks a port from within an existing range — never invent a new range ad-hoc. If a genuine need arises for a range not listed here, amend this file and the constitution together.

| Range       | Purpose                                          |
|-------------|--------------------------------------------------|
| 3000–3099   | UI services (Grafana and any future user-facing UIs) |
| 3100–3199   | Logs/RUM subsystem (Loki, Alloy collector + Faro receiver) |
| 8080–8099   | Container and exporter UIs (cAdvisor, etc.)      |
| 9090–9099   | Prometheus core and adjacent services            |
| 9100–9199   | Prometheus-ecosystem exporters                   |

## Current assignments

| Port   | Service        | Range           | Feature |
|--------|----------------|-----------------|---------|
| 3030   | Grafana        | 3000–3099       | F001    |
| 8081   | cAdvisor       | 8080–8099       | F001    |
| 9090   | Prometheus     | 9090–9099       | F001    |
| 9100   | node_exporter  | 9100–9199       | F001    |
| 9116   | snmp_exporter  | 9100–9199       | F002    |
| 9187   | postgres_exporter | 9100–9199    | F003 (Mneme; shared with any future feature reusing postgres_exporter on a different DB — F004+ adjusts this row if needed) |

## Reserved for later features

| Port   | Service                  | Range     | Feature    |
|--------|--------------------------|-----------|------------|
| 9093   | Alertmanager             | 9090–9099 | Alerting (TBD) |
| 3100   | Loki (HTTP)              | 3100–3199 | F004 (logs/RUM) |
| 3110   | Alloy UI                 | 3100–3199 | F004 (logs/RUM) — remapped off upstream default 12345 |
| 3111   | Alloy Faro receiver      | 3100–3199 | F004 (logs/RUM) — binds localhost behind the reverse proxy; remapped off upstream default 12345 |

Loki anchors the `3100–3199` band at its upstream default (3100); Alloy's UI and Faro receiver are remapped into the band (their upstream defaults — 12345 — fall outside every range and are arbitrary behind the proxy). These port numbers are pencilled here and finalized in F004's spec; when the feature lands they move into "Current assignments".

When these features land, they update the table above (moving the reservation into "Current assignments") rather than adding a new entry.

## Forbidden ports

These ports are owned by DSM itself or by common DSM services. Do not allocate to our stack under any circumstances.

| Port    | Owner                                          |
|---------|------------------------------------------------|
| 22      | SSH (DSM)                                      |
| 80, 443 | DSM reverse proxy (if enabled)                 |
| 5000    | DSM web UI (HTTP)                              |
| 5001    | DSM web UI (HTTPS)                             |

If a port collision is suspected at deploy time, `ss -tlnp | grep <port>` on the NAS identifies the culprit. See `docs/setup.md` §Troubleshooting.
