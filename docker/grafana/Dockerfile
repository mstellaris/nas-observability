ARG GRAFANA_VERSION=11.4.0
FROM grafana/grafana-oss:${GRAFANA_VERSION}

ARG GIT_SHA=dev
ARG VERSION=0.0.0

USER root

COPY provisioning/datasources/datasources.yaml /etc/grafana/provisioning/datasources/datasources.yaml
COPY provisioning/dashboards/dashboards.yaml /etc/grafana/provisioning/dashboards/dashboards.yaml
COPY dashboards/ /var/lib/grafana/dashboards/

COPY scripts/inject-build-metadata.sh /tmp/inject-build-metadata.sh
RUN sh /tmp/inject-build-metadata.sh "${VERSION}" "${GIT_SHA}" /var/lib/grafana/dashboards/stack-health.json \
 && rm /tmp/inject-build-metadata.sh \
 && chown -R grafana:root /var/lib/grafana/dashboards /etc/grafana/provisioning

USER grafana

LABEL org.opencontainers.image.source="https://github.com/mstellaris/nas-observability"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
