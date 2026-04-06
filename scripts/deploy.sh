#!/usr/bin/env bash
# =============================================================================
# Mistral 7B Production — Deploy & Manage
# Usage: ./scripts/deploy.sh [start|stop|restart|health|status|rolling-update|logs]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
GPUS=8
TOTAL_INSTANCES=$GPUS
BASE_PORT=8000

cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- Pre-flight checks ----
preflight() {
    log "Running pre-flight checks..."

    # Check Docker
    if ! command -v docker &>/dev/null; then
        err "Docker not found"; exit 1
    fi

    # Check NVIDIA runtime
    if ! docker info 2>/dev/null | grep -q nvidia; then
        err "NVIDIA Docker runtime not configured"; exit 1
    fi

    # Check GPU count
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [ "$GPU_COUNT" -lt "$GPUS" ]; then
        err "Expected $GPUS GPUs, found $GPU_COUNT"; exit 1
    fi
    log "Found $GPU_COUNT GPUs"

    # Check available VRAM
    for i in $(seq 0 $((GPUS-1))); do
        VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i $i)
        log "  GPU $i: ${VRAM}MB VRAM"
    done

    # Check disk space for model cache
    AVAIL_GB=$(df -BG /var/lib/docker | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$AVAIL_GB" -lt 50 ]; then
        warn "Only ${AVAIL_GB}GB disk available — model download needs ~15GB"
    fi

    # Check .env
    if [ ! -f "$ENV_FILE" ]; then
        warn ".env not found, copying from .env.example"
        cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    fi

    log "Pre-flight checks passed"
}

# ---- Start ----
start() {
    preflight
    log "Starting Mistral 7B production stack ($TOTAL_INSTANCES workers, one per GPU)..."

    # Pull images first
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

    # Start monitoring first, then vLLM instances
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d \
        prometheus grafana alertmanager loki promtail

    log "Starting vLLM workers (this can take a few minutes while weights are loaded)..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d \
        vllm-g0 vllm-g1 vllm-g2 vllm-g3 vllm-g4 vllm-g5 vllm-g6 vllm-g7

    # Wait for health
    log "Waiting for instances to become healthy..."
    wait_healthy 300

    log "Starting nginx gateway..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d nginx nginx-exporter

    log "Stack is up! Endpoint: https://$(hostname -I | awk '{print $1}')/v1/"
}

# ---- Stop ----
stop() {
    log "Stopping all services..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    log "Stopped."
}

# ---- Health check ----
wait_healthy() {
    local timeout=${1:-300}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        healthy=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
            grep -c '"Health":"healthy"' || true)
        if [ "$healthy" -ge "$TOTAL_INSTANCES" ]; then
            log "All $TOTAL_INSTANCES instances healthy"
            return 0
        fi
        echo -ne "\r  $healthy/$TOTAL_INSTANCES healthy (${elapsed}s elapsed)..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    warn "Timeout: only $healthy/$TOTAL_INSTANCES healthy after ${timeout}s"
    return 1
}

health() {
    echo "Instance Health:"
    echo "================"
    local healthy=0 unhealthy=0

    for gpu in $(seq 0 $((GPUS-1))); do
        port=$((BASE_PORT + gpu))
        name="vllm-g${gpu}"
        if curl -sf "http://localhost:$port/health" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $name (port $port)"
            healthy=$((healthy+1))
        else
            echo -e "  ${RED}✗${NC} $name (port $port)"
            unhealthy=$((unhealthy+1))
        fi
    done

    echo ""
    echo "Summary: $healthy healthy, $unhealthy unhealthy out of $TOTAL_INSTANCES"

    # Gateway check
    if curl -sf "http://localhost/health" &>/dev/null; then
        echo -e "Gateway:    ${GREEN}✓${NC} healthy"
    else
        echo -e "Gateway:    ${RED}✗${NC} unhealthy"
    fi

    # Prometheus check
    if curl -sf "http://localhost:9090/-/healthy" &>/dev/null; then
        echo -e "Prometheus: ${GREEN}✓${NC} healthy"
    else
        echo -e "Prometheus: ${RED}✗${NC} unhealthy"
    fi
}

# ---- Rolling update (zero-downtime) ----
rolling_update() {
    log "Starting rolling update..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

    # Update one GPU worker at a time to maintain capacity
    for gpu in $(seq 0 $((GPUS-1))); do
        name="vllm-g${gpu}"
        log "Updating GPU $gpu worker..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-deps "$name"

        local port=$((BASE_PORT + gpu))
        local tries=0
        while ! curl -sf "http://localhost:$port/health" &>/dev/null; do
            sleep 5
            tries=$((tries+1))
            if [ $tries -gt 60 ]; then
                err "$name failed to start, aborting rolling update"
                exit 1
            fi
        done
        log "  $name is healthy"
    done

    # Update gateway last
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-deps nginx nginx-exporter
    log "Rolling update complete"
}

# ---- Status ----
status() {
    docker compose -f "$COMPOSE_FILE" ps
}

# ---- Logs ----
logs() {
    local service=${2:-""}
    if [ -n "$service" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f "$service"
    else
        docker compose -f "$COMPOSE_FILE" logs -f --tail=100
    fi
}

# ---- Main ----
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
