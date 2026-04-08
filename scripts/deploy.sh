#!/usr/bin/env bash
# =============================================================================
# Mixed-Model Production — Deploy & Manage
# Usage: ./scripts/deploy.sh [start|stop|restart|health|status|rolling-update|logs]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
TOTAL_GPUS=8
DATA_ROOT_DEFAULT=/mnt/compass/mistral
PUBLIC_GATEWAY_HTTP_PORT_DEFAULT=8081

WORKER_SERVICES=(mistral-g0 mistral-g1 small32-tp4)
WORKER_PORTS=(8000 8001 8002)
MISTRAL_SERVICES=(mistral-g0 mistral-g1)
GATEWAY_SERVICES=(nginx-mistral nginx-small32 nginx-router nginx-exporter-mistral nginx-exporter-small32)
MONITORING_SERVICES=(prometheus grafana alertmanager loki promtail dcgm-exporter)

cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

get_env_value() {
    local key=$1
    local fallback=$2
    local value
    value=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$fallback"
    fi
}

preflight() {
    log "Running pre-flight checks..."

    if ! command -v docker &>/dev/null; then
        err "Docker not found"
        exit 1
    fi

    if ! docker info 2>/dev/null | grep -q nvidia; then
        err "NVIDIA Docker runtime not configured"
        exit 1
    fi

    local gpu_count
    gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [ "$gpu_count" -lt "$TOTAL_GPUS" ]; then
        err "Expected $TOTAL_GPUS GPUs, found $gpu_count"
        exit 1
    fi
    log "Found $gpu_count GPUs"

    local data_root log_root model_cache_root vllm_cache_root prometheus_data_root grafana_data_root loki_data_root
    data_root=$(get_env_value "DATA_ROOT" "$DATA_ROOT_DEFAULT")
    log_root=$(get_env_value "LOG_ROOT" "${data_root}/logs")
    model_cache_root=$(get_env_value "MODEL_CACHE_ROOT" "${data_root}/model-cache")
    vllm_cache_root=$(get_env_value "VLLM_CACHE_ROOT" "${data_root}/vllm-cache")
    prometheus_data_root=$(get_env_value "PROMETHEUS_DATA_ROOT" "${data_root}/prometheus")
    grafana_data_root=$(get_env_value "GRAFANA_DATA_ROOT" "${data_root}/grafana")
    loki_data_root=$(get_env_value "LOKI_DATA_ROOT" "${data_root}/loki")

    mkdir -p \
        "$data_root" \
        "$log_root/nginx-mistral" \
        "$log_root/nginx-small32" \
        "$model_cache_root" \
        "$vllm_cache_root" \
        "$prometheus_data_root" \
        "$grafana_data_root" \
        "$loki_data_root"

    if [ ! -f "$ENV_FILE" ]; then
        warn ".env not found, copying from .env.example"
        cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    fi

    if ! grep -qE '^HF_TOKEN=.+$' "$ENV_FILE"; then
        warn "HF_TOKEN is not set in .env. Hugging Face model downloads may fail for gated repos."
    fi

    log "Pre-flight checks passed"
}

wait_port_healthy() {
    local port=$1
    local name=$2
    local timeout=${3:-900}
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if curl -sf "http://localhost:${port}/health" &>/dev/null; then
            log "$name is healthy"
            return 0
        fi
        if docker compose -f "$COMPOSE_FILE" ps --status exited --services 2>/dev/null | grep -qx "$name"; then
            err "$name exited before becoming healthy"
            docker compose -f "$COMPOSE_FILE" logs --tail=80 "$name" || true
            return 1
        fi
        echo -ne "\r  waiting for $name on port $port (${elapsed}s elapsed)..."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    warn "Timeout waiting for $name to become healthy"
    return 1
}

wait_healthy() {
    local timeout=${1:-300}
    local elapsed=0
    local expected=${#WORKER_SERVICES[@]}
    while [ $elapsed -lt $timeout ]; do
        local healthy=0
        local i
        for i in "${!WORKER_SERVICES[@]}"; do
            if curl -sf "http://localhost:${WORKER_PORTS[$i]}/health" &>/dev/null; then
                healthy=$((healthy + 1))
            fi
        done
        if [ "$healthy" -ge "$expected" ]; then
            log "All $expected serving processes healthy"
            return 0
        fi
        echo -ne "\r  $healthy/$expected healthy (${elapsed}s elapsed)..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    warn "Timeout waiting for all serving processes to become healthy"
    return 1
}

start() {
    preflight
    log "Starting mixed-model stack: 2x Mistral 7B, 1x Mistral Small 3.2 TP4, GPUs 2-3 spare"

    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d "${MONITORING_SERVICES[@]}"

    log "Starting Mistral lane..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate "${MISTRAL_SERVICES[@]}"
    wait_port_healthy 8000 "mistral-g0" 1800
    wait_port_healthy 8001 "mistral-g1" 1800

    log "Starting Mistral Small 3.2 lane..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate small32-tp4
    wait_port_healthy 8002 "small32-tp4" 3600

    log "Waiting for all serving processes to become healthy..."
    wait_healthy 3600

    log "Starting model gateways..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate "${GATEWAY_SERVICES[@]}"

    local public_http_port
    public_http_port=$(get_env_value "PUBLIC_GATEWAY_HTTP_PORT" "$PUBLIC_GATEWAY_HTTP_PORT_DEFAULT")
    log "Public router:  http://127.0.0.1:${public_http_port}/v1/"
    log "Small 3.2 alias: http://127.0.0.1:${public_http_port}/mistral/small32/v1/"
    log "Mistral alias:  http://127.0.0.1:${public_http_port}/mistral/7b/v1/"
}

stop() {
    log "Stopping all services..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    log "Stopped."
}

health() {
    echo "Serving Process Health:"
    echo "======================"
    local healthy=0 unhealthy=0
    local i

    for i in "${!WORKER_SERVICES[@]}"; do
        local name="${WORKER_SERVICES[$i]}"
        local port="${WORKER_PORTS[$i]}"
        if curl -sf "http://localhost:$port/health" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $name (port $port)"
            healthy=$((healthy + 1))
        else
            echo -e "  ${RED}✗${NC} $name (port $port)"
            unhealthy=$((unhealthy + 1))
        fi
    done

    echo ""
    echo "Summary: $healthy healthy, $unhealthy unhealthy out of ${#WORKER_SERVICES[@]}"

    local public_http_port
    public_http_port=$(get_env_value "PUBLIC_GATEWAY_HTTP_PORT" "$PUBLIC_GATEWAY_HTTP_PORT_DEFAULT")

    if curl -sf "http://localhost:${public_http_port}/health" &>/dev/null; then
        echo -e "Public router:    ${GREEN}✓${NC} healthy"
    else
        echo -e "Public router:    ${RED}✗${NC} unhealthy"
    fi

    if docker compose -f "$COMPOSE_FILE" ps nginx-mistral --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
        echo -e "Mistral gateway:  ${GREEN}✓${NC} healthy"
    else
        echo -e "Mistral gateway:  ${RED}✗${NC} unhealthy"
    fi

    if docker compose -f "$COMPOSE_FILE" ps nginx-small32 --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
        echo -e "Small32 gateway:  ${GREEN}✓${NC} healthy"
    else
        echo -e "Small32 gateway:  ${RED}✗${NC} unhealthy"
    fi

    if curl -sf "http://localhost:9090/-/healthy" &>/dev/null; then
        echo -e "Prometheus:      ${GREEN}✓${NC} healthy"
    else
        echo -e "Prometheus:      ${RED}✗${NC} unhealthy"
    fi
}

rolling_update() {
    log "Starting rolling update..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

    local i
    for i in "${!WORKER_SERVICES[@]}"; do
        local name="${WORKER_SERVICES[$i]}"
        local port="${WORKER_PORTS[$i]}"
        log "Updating $name..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-deps "$name"
        local tries=0
        while ! curl -sf "http://localhost:$port/health" &>/dev/null; do
            sleep 5
            tries=$((tries + 1))
            if [ $tries -gt 120 ]; then
                err "$name failed to start, aborting rolling update"
                exit 1
            fi
        done
        log "  $name is healthy"
    done

    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-deps "${GATEWAY_SERVICES[@]}"
    log "Rolling update complete"
}

status() {
    docker compose -f "$COMPOSE_FILE" ps
}

logs() {
    local service=${2:-""}
    if [ -n "$service" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f "$service"
    else
        docker compose -f "$COMPOSE_FILE" logs -f --tail=100
    fi
}

case "${1:-help}" in
    start)          start ;;
    stop)           stop ;;
    restart)        stop; start ;;
    health)         health ;;
    status)         status ;;
    rolling-update) rolling_update ;;
    logs)           logs "$@" ;;
    *)
        echo "Usage: $0 {start|stop|restart|health|status|rolling-update|logs [service]}"
        exit 1
        ;;
esac
