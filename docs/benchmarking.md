# Benchmarking

This document captures the benchmark style used for this deployment and the current measured baseline on the dedicated `8x H100 80GB` node.

## Standard Metrics

For this stack, benchmark results should be reported as a set of metrics instead of one headline number:

- `RPS`: requests per second
- `TPS`: output tokens per second
- `TTFT`: time to first token
- `E2E latency`: full request latency
- `p50` and `p95` latency
- success rate
- queue depth during the run

That makes the results comparable across prompt sizes and concurrency levels.

## Current Harness

The repository benchmark harness is:

```bash
./scripts/benchmark.sh
```

It currently reports:

- successful and failed requests
- success rate
- wall-clock duration
- observed requests/sec
- average latency
- p50 latency
- p95 latency

Pair benchmark runs with Grafana and Prometheus for:

- generation throughput
- queue depth
- requests running
- per-worker request rate
- GPU utilization
- GPU memory used
- GPU power and temperature

## Current Baseline

These runs were taken against the working internal HTTPS gateway with:

- model: `mistralai/Mistral-7B-Instruct-v0.3`
- topology: `8` workers, `1` worker per GPU
- workload shape: short chat requests
- `MAX_TOKENS=64`

Measured results:

| Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P95 Latency | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `600` | `16` | `100%` | `12.77` | `1.191s` | `1.273s` | queue stayed `0` |
| `600` | `32` | `100%` | `27.27` | `1.119s` | `1.223s` | queue stayed `0` |
| `600` | `64` | `100%` | `50.00` | `1.114s` | `1.472s` | queue stayed `0` |

Interpretation:

- the current stack is stable through at least `64` concurrent short chat requests
- the gateway is no longer the limiting factor for this test shape
- this is still a short-output benchmark, not a worst-case long-context result

## What To Publish

When sharing capacity externally, include:

- hardware shape
- model name
- worker topology
- prompt size assumptions
- output token cap
- concurrency
- success rate
- requests/sec
- tokens/sec
- p50/p95 TTFT
- p50/p95 E2E latency

Do not publish only one number like “this box does X TPS” without the workload shape.

## Recommended Next Runs

To make the benchmark story stronger, add:

1. `TEST_MODE=tools` at `24` and `32` concurrency
2. `TEST_MODE=stream` at `24` and `32` concurrency
3. longer-output runs with `MAX_TOKENS=256`
4. larger prompt-size tests
5. a sustained run long enough to observe thermal and steady-state behavior

## Integration Notes

The integration team should treat these results as:

- valid for the current gateway and worker topology
- valid for short-form chat requests
- not yet a guarantee for long prompts, large tool schemas, or long outputs

The most useful feedback from integration is:

- expected request burstiness
- expected prompt and output sizes
- whether retries happen upstream
- timeout expectations
- whether the router adds its own per-user or per-key throttling
