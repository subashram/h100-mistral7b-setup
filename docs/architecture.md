# Architecture

This deployment is designed for a single dedicated `8x H100 80GB` node serving `mistralai/Mistral-7B-Instruct-v0.3`.

## Topology

```mermaid
flowchart TD
    public["Host nginx<br/>public :80"] --> internal["Container nginx<br/>127.0.0.1:8081 / 8443"]
    internal --> g0["vLLM g0<br/>GPU 0"]
    internal --> g1["vLLM g1<br/>GPU 1"]
    internal --> g2["vLLM g2<br/>GPU 2"]
    internal --> g3["vLLM g3<br/>GPU 3"]
    internal --> g4["vLLM g4<br/>GPU 4"]
    internal --> g5["vLLM g5<br/>GPU 5"]
    internal --> g6["vLLM g6<br/>GPU 6"]
    internal --> g7["vLLM g7<br/>GPU 7"]

    g0 --> obs["Prometheus / Grafana / Alertmanager / Loki"]
    g1 --> obs
    g2 --> obs
    g3 --> obs
    g4 --> obs
    g5 --> obs
    g6 --> obs
    g7 --> obs
```

## Key Design Choices

- One `vLLM` worker per GPU is the baseline.
- The public entrypoint stays on the host `nginx`.
- The application gateway runs in Docker and binds only to `127.0.0.1`.
- Heavy persistent state lives under `/mnt/compass/mistral`.
- App code and deployment config live under `/opt/compass/mistral`.

## Runtime Layout

- `/opt/compass/mistral`
  Purpose: deployed repo, compose file, configs, scripts
- `/mnt/compass/mistral/model-cache`
  Purpose: Hugging Face model weights and cache
- `/mnt/compass/mistral/vllm-cache`
  Purpose: `vLLM` compile and runtime cache
- `/mnt/compass/mistral/prometheus`
  Purpose: Prometheus TSDB
- `/mnt/compass/mistral/grafana`
  Purpose: Grafana state
- `/mnt/compass/mistral/loki`
  Purpose: Loki data
- `/mnt/compass/mistral/logs`
  Purpose: application and gateway logs

## Network Model

- Public HTTP currently terminates at host `nginx` on port `80`.
- Host `nginx` proxies to `127.0.0.1:8081`.
- Containerized `nginx` proxies to the eight `vLLM` workers over the Docker network.
- Worker health and debugging remain available on ports `8000` to `8007`.

## Current Gaps

- Host-side TLS on public `443` is not set up yet.
- External reachability depends on cloud firewall / NSG rules.
- Monitoring UIs are intended for SSH tunnel access first, not public exposure.
