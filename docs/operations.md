# Operations

This document covers day-2 commands and checks for the running stack.

## Common Commands

```bash
./scripts/deploy.sh start
./scripts/deploy.sh stop
./scripts/deploy.sh restart
./scripts/deploy.sh status
./scripts/deploy.sh health
./scripts/deploy.sh logs
./scripts/deploy.sh logs vllm-g3
./scripts/deploy.sh rolling-update
```

## Health Checks

Primary operator check:

```bash
./scripts/deploy.sh health
```

Direct worker checks:

```bash
curl http://localhost:8000/health
curl http://localhost:8007/health
```

Internal gateway check:

```bash
curl http://127.0.0.1:8081/health
```

Public host entrypoint check:

```bash
curl -I http://127.0.0.1/
```

## Useful Logs

Container logs:

```bash
docker compose logs --tail=100 vllm-g0
docker compose logs --tail=100 nginx
docker compose logs --tail=100 prometheus
```

Persistent log location:

- `/mnt/compass/mistral/logs`
- `/mnt/compass/mistral/logs/nginx`

## GPU Checks

Quick GPU view:

```bash
nvidia-smi
```

Compact view:

```bash
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader
```

Healthy steady state for the current stack usually looks like:

- all `8` GPUs allocated
- about `72 GiB` used per GPU at idle after warmup

## Benchmarking

Quick load test:

```bash
./scripts/benchmark.sh
```

Targeted API validation:

```bash
./scripts/api-test.sh
TEST_MODE=tools ./scripts/api-test.sh
```

## Monitoring Access

Preferred access method: SSH tunnel.

Example:

```bash
ssh -i ~/.ssh/id_ed25519_compass_mistral \
  -L 8088:localhost:80 \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9093:localhost:9093 \
  -L 3100:localhost:3100 \
  compass@20.174.12.45
```

Then open:

- `http://localhost:8088`
- `http://localhost:3000`
- `http://localhost:9090`
- `http://localhost:9093`

## Current Operational Risks

- public TLS is not yet configured on the host
- direct external HTTP is still blocked by network policy outside the machine
- alerts still need real destinations and final tuning
