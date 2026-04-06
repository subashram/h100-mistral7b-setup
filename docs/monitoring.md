# Monitoring

The stack includes:

- Prometheus
- Grafana
- Alertmanager
- Loki
- Promtail
- Nginx Prometheus exporter

## Endpoints

- Grafana: `localhost:3000`
- Prometheus: `localhost:9090`
- Alertmanager: `localhost:9093`
- Loki: `localhost:3100`

Recommended access is via SSH tunnel, not public exposure.

## Data Paths

- Prometheus: `/mnt/compass/mistral/prometheus`
- Grafana: `/mnt/compass/mistral/grafana`
- Loki: `/mnt/compass/mistral/loki`
- Logs: `/mnt/compass/mistral/logs`

## Metrics Sources

- `vLLM` worker metrics from each worker’s `/metrics`
- Nginx exporter metrics from the internal gateway
- optional host GPU metrics from DCGM exporter at `host.docker.internal:9400`

## What To Verify In Grafana

- request throughput
- latency
- worker availability
- error rate
- queue-related pressure
- GPU memory usage and saturation if DCGM exporter is enabled

## Alerts

Prometheus rules are defined in:

- `monitoring/prometheus/alerts.yml`

Alertmanager config is defined in:

- `monitoring/prometheus/alertmanager.yml`

Before relying on alerts in production:

- set real Slack or email destinations
- test notification routing
- confirm dashboard queries match the exact `vLLM 0.19.0` metric names in use
