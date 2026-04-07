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

## Router Handoff

The service is intended to be consumed as an OpenAI-compatible endpoint behind an upstream router.

Router teams should receive:

- Base URL: `https://<public-host>/v1`
- Auth header: `Authorization: Bearer <API_KEY>`
- Health check path: `GET /health`
- Model name: `mistralai/Mistral-7B-Instruct-v0.3`
- Gateway timeout profile:
  - read timeout: `300s`
  - send timeout: `300s`
- Retry behavior on upstream failure:
  - retry on `error`, `timeout`, `502`, `503`
  - up to `3` upstream tries
  - retry window: `10s`

Primary API paths:

- `POST /v1/chat/completions`
- `GET /v1/models`

Example request:

```bash
curl https://<public-host>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <API_KEY>' \
  -d '{
    "model": "mistralai/Mistral-7B-Instruct-v0.3",
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

Current status:

- Internal gateway: `https://127.0.0.1:8443/v1`
- SSH-tunneled gateway from an operator workstation: `https://127.0.0.1:18443/v1`
- Final public `443` endpoint still depends on host TLS and firewall completion

## Current Gateway Safeguards

Current Nginx gateway behavior:

- API key authentication is required on `/v1/`
- global request limiting is enabled per client IP
  - sustained rate: `200 r/s`
  - burst: `100`
  - limit response: `429`
- no per-API-key rate limit is enabled right now
- request body limit: `10m`
- streaming responses are supported with proxy buffering disabled
- request IDs are added with `X-Request-ID`
- upstream selection uses `least_conn`

Why this matters for integration:

- shared test keys will not be throttled just because many requests use the same key
- upstream routers can still do user-, tenant-, or key-level policy separately
- this gateway still protects the box from obvious edge floods

Feedback needed from the integration team:

- expected steady-state requests/sec
- expected burst profile
- expected prompt and output sizes
- whether upstream retries are enabled
- whether upstream already enforces per-user or per-key rate limits
- target timeout/SLA expectations

## Host nginx Integration

The host `nginx` currently proxies public HTTP traffic to:

```text
http://127.0.0.1:8081
```

This keeps public ports on the host while the app gateway stays internal to the machine.

Ingress is intentionally split into two tiers:

- host `nginx`
  Purpose: public entrypoint, host TLS, public `80/443`, and firewall-facing exposure control
- container `nginx`
  Purpose: API-key auth, rate limiting, request routing, upstream balancing, metrics, and structured gateway logs

The recommended operating model is:

- host `nginx` is the only internet-facing listener
- container `nginx` stays private on `127.0.0.1:8081/8443`
- vLLM workers stay behind the container gateway on the Docker network

The recommended host frontend config is included in the repo at:

- `nginx/host-public-nginx.conf.example`

It is intended to be copied to the host, adapted for the final hostname and certificate paths, then enabled with:

```bash
sudo cp nginx/host-public-nginx.conf.example /etc/nginx/conf.d/mistral.conf
sudo nginx -t
sudo systemctl reload nginx
```

## Host TLS Follow-up

The intended final state is for host `nginx` to terminate TLS on public `443` and proxy to the internal gateway on `127.0.0.1:8081`.

What still needs to happen:

1. choose the certificate source
   - real CA-issued certificate for production
   - temporary self-signed certificate only for internal testing
2. place the certificate and key on the host
   - recommended path: `/etc/nginx/certs/`
3. add a host `nginx` `server` block for `443 ssl`
4. configure that `443` server block to proxy to `http://127.0.0.1:8081`
5. keep port `80` as a redirect to `https://$host$request_uri`
6. validate with `sudo nginx -t` and reload host `nginx`
7. open cloud firewall / NSG rules for `443`

Recommended final pattern:

- host `nginx` handles public `80/443`
- host `80` redirects to `443`
- host `443` terminates TLS
- host `443` proxies to `127.0.0.1:8081`
- the containerized gateway remains internal-only on `127.0.0.1:8081/8443`

Recommended supporting settings:

- keep `.env` at `GATEWAY_BIND_HOST=127.0.0.1`
- keep Docker port publishing on `127.0.0.1:8081:8081` and `127.0.0.1:8443:8443`
- expose only host `80/443` publicly
- do not expose `8081/8443` directly through the cloud firewall

## Known Follow-ups

- Add public TLS on host `nginx`
- Open cloud firewall / NSG rules for `80` and later `443`
- Replace bootstrap certs and bootstrap API keys
