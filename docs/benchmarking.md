# Benchmarking

This document captures the benchmark style used for this deployment and the current measured baseline on the dedicated `8x H100 80GB` node.

Important note:

- the measured results below were gathered on the earlier `8x single-GPU Mistral 7B` layout
- they remain useful as a historical baseline for the `Mistral` lane
- they should not be treated as the expected performance of the current mixed `Mistral 7B + Mistral Small 3.2` topology

## Current Mixed-Lane Results

The current mixed deployment adds a `Mistral Small 3.2` lane on GPUs `4-7` behind the explicit router path:

- `/mistral/small32/v1`

Measured results on the live box:

| Model | Workload | Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P95 Latency | Notes |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| `Mistral Small 3.2` | chat, `MAX_TOKENS=128` | `200` | `16` | `100%` | `25.00` | `0.595s` | `0.667s` | first validation run |
| `Mistral Small 3.2` | chat, `MAX_TOKENS=128` | `600` | `32` | `100%` | `46.15` | `0.632s` | `0.715s` | stable baseline |
| `Mistral Small 3.2` | tools, `MAX_TOKENS=128` | `200` | `12` | `100%` | `33.33` | `0.270s` | `0.387s` | tool calling stable |
| `Mistral Small 3.2` | chat, `MAX_TOKENS=128` | `600` | `48` | `100%` | `60.00` | `0.683s` | `0.785s` | still healthy |

Operational note:

- earlier attempts at `tools@24` and `chat@64` hit the `small32` gateway rate limiter and returned `429`s
- those runs reflected ingress policy, not a model failure

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

## Test Environment

These benchmark results were taken on:

- hardware: `8x NVIDIA H100 80GB HBM3`
- serving topology: `8` vLLM workers, `1` worker per GPU
- model: `mistralai/Mistral-7B-Instruct-v0.3`
- dtype: `bfloat16`
- gateway: `nginx` reverse proxy with bearer-token auth
- vLLM baseline tuning:
  - `GPU_MEMORY_UTILIZATION=0.90`
  - `MAX_MODEL_LEN=8192`
  - `MAX_NUM_BATCHED_TOKENS=16384`
  - `MAX_NUM_SEQS=256`

Unless otherwise noted, runs were sent to the internal HTTPS gateway and observed with the Grafana dashboard plus Prometheus metrics.

## Comparison Rules

When comparing another deployment to these results, try to keep these factors aligned:

- same model and model revision
- same worker topology
- same prompt style and approximate prompt length
- same `MAX_TOKENS`
- same concurrency
- same request mode: `chat`, `stream`, or `tools`

If those differ, the results are still useful, but they are no longer an apples-to-apples comparison.

## Benchmark Results

### Short Chat Baseline

Workload shape:

- request mode: `chat`
- prompt style: short single-turn prompt
- output cap: `MAX_TOKENS=64`

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

### Longer Output Chat

Workload shape:

- request mode: `chat`
- prompt style: short single-turn prompt
- output cap: `MAX_TOKENS=256`

Measured results:

| Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P95 Latency | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `400` | `32` | `100%` | `22.22` | `1.425s` | `1.718s` | queue stayed `0` |

Interpretation:

- increasing output length reduced throughput as expected
- latency stayed well-behaved with no queue growth
- this is a better comparison point than the short chat baseline for integrations expecting larger responses

### Streaming

Workload shape:

- request mode: `stream`
- prompt style: short single-turn prompt
- output cap: `MAX_TOKENS=128`

Measured results:

| Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P95 Latency | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `200` | `24` | `100%` | `15.38` | `1.435s` | `1.995s` | queue stayed `0` |

Interpretation:

- streaming remained stable under moderate concurrency
- p95 was higher than short-form chat, which is expected because the request stays open while tokens are emitted

### Tool Calling

Workload shape:

- request mode: `tools`
- tool schema: simple weather-style test function
- output cap: `MAX_TOKENS=128`

Important note:

- early tool-calling benchmark failures were caused by an output-format mismatch in the Mistral tool path, not by hardware or gateway capacity
- valid tool-calling results only apply after enabling the current vLLM Mistral parser and chat-template settings

Measured results after the fix:

| Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P95 Latency | Notes |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `200` | `24` | `100%` | `25.00` | `0.843s` | `1.067s` | post-fix run |
| `200` | `32` | `100%` | `33.33` | `0.879s` | `1.274s` | post-fix run |

Interpretation:

- the tool-calling path is now stable under concurrency
- the fixed configuration should be preserved when comparing future tool benchmarks

### Sustained Chat Run

Workload shape:

- request mode: `chat`
- prompt style: short single-turn prompt
- output cap: `MAX_TOKENS=128`
- duration target: multi-minute soak

Measured result:

| Total Requests | Concurrency | Success Rate | Req/s | Avg Latency | P50 Latency | P95 Latency | Wall Time | Notes |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `15000` | `32` | `100%` | `23.40` | `1.346s` | `1.350s` | `1.479s` | `641s` | about `10.7` minutes, queue stayed `0` |

Observed checkpoints during the soak:

- about `2` minutes: queue `0`, running requests `17`, generation throughput about `1042 tok/s`
- about `5` minutes: queue `0`, running requests `14`, generation throughput about `2596 tok/s`
- about `8` minutes: queue `0`, running requests `14`, generation throughput about `2577 tok/s`

Interpretation:

- the stack sustained a real multi-minute workload without queue buildup or errors
- latency stayed stable through the soak
- temperatures, GPU memory, and request distribution remained healthy in Grafana

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

A concise publishable summary for this deployment is:

- `Mistral-7B-Instruct-v0.3`
- `8x H100 80GB`
- `8` vLLM workers, `1` per GPU
- short chat benchmark:
  - `600 req @ concurrency 64`
  - `100%` success
  - `50.00 req/s`
  - `1.114s` average latency
  - `1.472s` p95 latency
- sustained chat benchmark:
  - `15000 req @ concurrency 32`
  - `100%` success
  - `23.40 req/s`
  - `1.346s` average latency
  - `1.479s` p95 latency
- tool benchmark after parser/template fix:
  - `200 req @ concurrency 32`
  - `100%` success
  - `33.33 req/s`
  - `0.879s` average latency
  - `1.274s` p95 latency

## Recommended Next Runs

To make the benchmark story stronger, add:

1. larger prompt-size tests
2. larger tool schemas that match real integration payloads
3. mixed request-type runs with `chat`, `stream`, and `tools` together
4. retry-behavior testing with the upstream router in the loop
5. longer soaks at higher concurrency or higher output caps

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
