# nas-observability
Synology observability stack

nas-observability is a self-hosted observability stack for Synology NAS systems and any Docker containers running on them. It combines Prometheus, Grafana, and standard exporters (node_exporter, cAdvisor, snmp_exporter) into a single Docker Compose deployment, with dashboards and alert rules baked into a custom Grafana image. It's designed for single-NAS homelab use, not multi-host enterprise monitoring. Consumers (such as the Mneme PKM system) expose /metrics endpoints; nas-observability scrapes them and provides operational visibility.