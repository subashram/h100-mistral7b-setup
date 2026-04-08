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
./scripts/deploy.sh logs small32-tp4
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
curl http://localhost:8001/health
curl http://localhost:8002/health
```

Internal gateway check:

```bash
curl http://127.0.0.1:8081/health
curl -k https://127.0.0.1:8443/health
```

Public host entrypoint check:

```bash
curl -I http://127.0.0.1/
```

## Useful Logs

Container logs:

```bash
docker compose logs --tail=100 mistral-g0
docker compose logs --tail=100 small32-tp4
docker compose logs --tail=100 nginx-mistral
docker compose logs --tail=100 nginx-small32
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

- GPUs `0-1` allocated to `Mistral`
- GPUs `4-7` allocated to `Mistral Small 3.2`
- GPUs `2-3` available as spare capacity

## Benchmarking

Quick load test:

```bash
./scripts/benchmark.sh
TARGET_STACK=small32 ./scripts/benchmark.sh
```

Targeted API validation:

```bash
./scripts/api-test.sh
TEST_MODE=tools ./scripts/api-test.sh
TARGET_STACK=small32 ./scripts/api-test.sh
./scripts/capability-test.sh
TARGET_STACK=small32 ./scripts/capability-test.sh
```

Use `capability-test.sh` when you want to verify both:

- the features this deployment intentionally supports
- the platform-style features that are intentionally not exposed here, such as OCR and Document QnA

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
  compass@<h100-server-ip>
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

## HTTPS Rollout Checklist

Before declaring HTTPS production-ready:

- confirm cloud/network ingress for `443`
- install the final host certificate and key
- add a host `nginx` `443` server block
- keep the host `80 -> 443` redirect
- validate locally:
  - `curl -kI https://127.0.0.1`
  - `curl -I http://127.0.0.1`
- validate externally after firewall changes:
  - `curl -I http://<public-ip>`
  - `curl -kI https://<public-ip>` or use the real hostname
