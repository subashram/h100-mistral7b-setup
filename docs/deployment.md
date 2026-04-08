# Deployment

This document covers the mixed-model deployment path for the target host.

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
- `PUBLIC_GATEWAY_BIND_HOST`
- `PUBLIC_GATEWAY_HTTP_PORT`
- `DATA_ROOT`

Current baseline values:

- public router: `127.0.0.1:8081`
- public host proxy: port `80`
- worker ports: `8000`, `8001`, and `8002`
- GPU placement:
  - `Mistral`: GPUs `0-1`
  - spare: GPUs `2-3`
  - `Small32`: GPUs `4-7`

## Start Sequence

Use:

```bash
./scripts/deploy.sh start
```

The deploy script currently:

1. runs preflight checks
2. starts monitoring services
3. starts the two `Mistral` workers on GPUs `0-1`
4. starts the `Mistral Small 3.2` TP4 worker on GPUs `4-7`
5. waits for all three serving processes to become healthy
6. starts the two internal gateways, the public router, and the Nginx exporters

## GPU Topology Note

This machine exposes `NV18` between every GPU pair, so the box behaves like a fully connected NVLink fabric from the model-serving point of view.

That means the `Mistral Small 3.2` placement decision is driven more by NUMA locality than by missing GPU-to-GPU links:

- GPUs `0-3` are aligned with one CPU/NUMA half
- GPUs `4-7` are aligned with the other

The repository therefore places the four-GPU `Mistral Small 3.2` worker on GPUs `4-7` to keep the tensor-parallel worker within one NUMA half of the machine.

## Verify Deployment

Use:

```bash
./scripts/deploy.sh health
./scripts/smoke-test.sh
./scripts/api-test.sh
TARGET_STACK=small32 ./scripts/api-test.sh
```

Typical internal endpoints:

```bash
ENDPOINT=https://127.0.0.1:8443/v1 ./scripts/api-test.sh
ENDPOINT=https://127.0.0.1:8443/mistral/small32/v1 MODEL=mistralai/Mistral-Small-3.2-24B-Instruct-2506 ./scripts/api-test.sh
ENDPOINT=https://127.0.0.1:8443/mistral/7b/v1 ./scripts/api-test.sh
```

## Router Handoff

The public router is intended to be consumed as an OpenAI-compatible endpoint behind an upstream router.

Router teams should receive:

- Default alias: `https://<public-host>/v1`
- Explicit `Mistral` alias: `https://<public-host>/mistral/7b/v1`
- Explicit `Mistral Small 3.2` alias: `https://<public-host>/mistral/small32/v1`
- Auth header: `Authorization: Bearer <API_KEY>`
- Health check path: `GET /health`
- Model names:
  - `mistralai/Mistral-7B-Instruct-v0.3`
  - `mistralai/Mistral-Small-3.2-24B-Instruct-2506`
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

- Public/internal router aliases:
  - `https://127.0.0.1:8443/v1`
  - `https://127.0.0.1:8443/mistral/7b/v1`
  - `https://127.0.0.1:8443/mistral/small32/v1`
- Final public `443` endpoint still depends on host TLS and firewall completion

## Current Gateway Safeguards

Current gateway behavior:

- API key authentication is required on `/v1/`
- `Mistral` lane uses a higher global per-IP limit than `Small32`
- `Small32` is intentionally tighter because the model lane is larger and more expensive per request
- no per-API-key rate limit is enabled right now
- request body limit: `10m`
- streaming responses are supported with proxy buffering disabled
- request IDs are added with `X-Request-ID`
- upstream selection uses `least_conn`

URI routing behavior:

- `/v1` currently routes to the `Mistral` lane by default
- `/mistral/7b/v1` explicitly routes to the `Mistral` lane
- `/mistral/small32/v1` explicitly routes to the `Mistral Small 3.2` lane
- the `/v1` alias can be switched later without changing the explicit paths

## Changing The Default Route

If you want `/v1` to point somewhere else, edit:

- `nginx/router-gateway.conf`

The router keeps explicit routes stable and uses `/v1` only as a default alias.

Current default:

```nginx
location /v1/ {
    proxy_pass http://mistral_lane/v1/;
    ...
}
```

To move the default alias to `Mistral Small 3.2`:

```nginx
location /v1/ {
    proxy_pass http://small32_lane/v1/;
    ...
}
```

Then reload only the router layer:

```bash
docker compose up -d --force-recreate --no-deps nginx-router
./scripts/deploy.sh health
```

Recommended rule:

- keep the explicit namespaced routes stable
- only change `/v1` when you want to shift the default integration target
- avoid changing model names, gateway names, and URI aliases all at once

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
- the public router is the only internet-facing container listener
- the lane gateways stay private on the Docker network
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

The intended final state is for host `nginx` to terminate TLS on public `443` and proxy to the public router on `127.0.0.1:8081`.

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
- host `443` proxies to the public router on `127.0.0.1:8081`
- the lane gateways remain internal-only on the Docker network

Recommended supporting settings:

- keep `.env` at `PUBLIC_GATEWAY_BIND_HOST=127.0.0.1`
- keep Docker port publishing internal where possible
- expose only host `80/443` publicly
- do not expose internal worker or lane-gateway ports directly through the cloud firewall

## Known Follow-ups

- Add public TLS on host `nginx`
- Open cloud firewall / NSG rules for `80` and later `443`
- Replace bootstrap certs and bootstrap API keys
