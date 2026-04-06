# Deployment

This document covers the current deployment path that is already working on the target host.

## Host Preparation

Required software:

- NVIDIA drivers with `nvidia-smi`
- Docker Engine
- Docker Compose plugin
- NVIDIA Container Toolkit
- `curl`
- `jq`
- `git`
- `openssl`

Run:

```bash
./scripts/host-prereqs.sh report
```

On Ubuntu, install missing pieces with:

```bash
./scripts/host-prereqs.sh install
```

## Recommended Host Layout

- deploy user: `compass`
- app root: `/opt/compass/mistral`
- persistent data: `/mnt/compass/mistral`

Expected subdirectories:

- `/mnt/compass/mistral/model-cache`
- `/mnt/compass/mistral/vllm-cache`
- `/mnt/compass/mistral/prometheus`
- `/mnt/compass/mistral/grafana`
- `/mnt/compass/mistral/loki`
- `/mnt/compass/mistral/logs`

## Environment Setup

Create the runtime config:

```bash
cp .env.example .env
```

Review at least:

- `HF_TOKEN`
- `API_KEYS`
- `GRAFANA_ADMIN_PASSWORD`
- `GATEWAY_BIND_HOST`
- `GATEWAY_HTTP_PORT`
- `DATA_ROOT`

Current baseline values:

- internal gateway: `127.0.0.1:8081`
- public host proxy: port `80`
- worker ports: `8000` through `8007`

## Start Sequence

Use:

```bash
./scripts/deploy.sh start
```

The deploy script currently:

1. runs preflight checks
2. starts monitoring services
3. starts `vllm-g0` first to warm the shared model cache
4. starts the remaining `7` workers
5. waits for all workers to become healthy
6. starts the internal gateway and Nginx exporter

## Verify Deployment

Use:

```bash
./scripts/deploy.sh health
./scripts/smoke-test.sh
./scripts/api-test.sh
```

Typical internal endpoint:

```bash
ENDPOINT=http://127.0.0.1:8081/v1 ./scripts/api-test.sh
```

## Host nginx Integration

The host `nginx` currently proxies public HTTP traffic to:

```text
http://127.0.0.1:8081
```

This keeps public ports on the host while the app gateway stays internal to the machine.

## Known Follow-ups

- Add public TLS on host `nginx`
- Open cloud firewall / NSG rules for `80` and later `443`
- Replace bootstrap certs and bootstrap API keys
