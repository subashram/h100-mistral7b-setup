# Mistral 7B Production Deployment — 8×H100 Node

## Architecture Overview

```
                        ┌─────────────────────────────────────────────┐
                        │              API Gateway (Nginx)            │
                        │   • TLS termination   • Rate limiting       │
                        │   • API key auth      • Request buffering   │
                        │   • Health-aware LB    • Access logging      │
                        └────────────────┬────────────────────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
             ┌────────────┐      ┌────────────┐      ┌────────────┐
             │  vLLM Pool │      │  vLLM Pool │      │  vLLM Pool │  ... (8 pools)
             │   GPU 0    │      │   GPU 1    │      │   GPU 2    │
             │ 3 instances│      │ 3 instances│      │ 3 instances│
             └─────┬──────┘      └─────┬──────┘      └─────┬──────┘
                   │                   │                   │
             ┌─────▼───────────────────▼───────────────────▼──────┐
             │                  Prometheus + Grafana               │
             │   • Queue depth   • Latency p50/p95/p99            │
             │   • GPU util      • Token throughput               │
             │   • Error rates   • KV cache usage                 │
             └────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env with your model path, API keys, etc.

# 2. Launch everything
./scripts/deploy.sh start

# 3. Verify health
./scripts/deploy.sh health

# 4. Run a test request
./scripts/smoke-test.sh
```

## Components

| Component           | Purpose                                      |
|---------------------|----------------------------------------------|
| `docker-compose.yml`| Orchestrates all vLLM instances + infra       |
| `nginx/`            | API gateway with auth, rate limiting, TLS     |
| `monitoring/`       | Prometheus + Grafana dashboards               |
| `scripts/`          | Deploy, health check, smoke test, rollback    |
| `systemd/`          | Alternative: bare-metal systemd units         |
| `k8s/`              | Alternative: Kubernetes manifests             |

## Deployment Options

1. **Docker Compose** (recommended for single-node): `docker compose up -d`
2. **Systemd** (bare metal): `./scripts/deploy.sh systemd-install`
3. **Kubernetes**: `kubectl apply -k k8s/`
