# Causely Demo Environment

This repo sets up a local Kubernetes environment for testing and demonstrating Causely's root cause analysis capabilities. It runs the [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/) app on a `kind` cluster, injects failures through application code changes and Chaos Mesh, and verifies that Causely correctly identifies the root cause and surfaces the right symptoms.

The primary scenario targets the checkout service with a realistic application logic regression: a cart bundle optimization that assumes at least two items and panics on single-item orders. A second benchmark scenario covers a payment service fraud check misconfiguration that rejects every transaction. All scenarios have defined recovery paths and expected Causely signals to validate against.

### Deployment modes

The demo supports two modes controlled by whether Causely is deployed before `setup` runs:

| Mode | How to trigger | OTel trace export |
|---|---|---|
| **Causely mode** | Deploy Causely first, then run `setup` | OTel collector exports traces to `mediator.causely-mediation:54318` — topology and blast radius are populated |
| **Baseline mode** | Run `setup` without Causely deployed | OTel collector uses chart defaults only — no Causely trace ingestion |

`setup` detects the `causely` namespace automatically and applies `manifests/otel-collector/values-causely-traces.yaml` as a Helm overlay when present. No manual flag is needed.

---

## Setup

### Prerequisites

- `kind`
- `kubectl`
- `helm`
- `jq`
- `curl`
- `uv`
- Causely running on the same cluster in namespace `causely`

### Install

Clone the source used for scenario builds:

```bash
./scripts/checkout-scenarios.sh source-init
```

Create or reuse the cluster, install the demo:

```bash
./scripts/demo-testbed.sh setup
```

### Quick Start

Start the primary checkout scenario:

```bash
./scripts/checkout-scenarios.sh scenario-start
```

List the benchmark scenarios:

```bash
./scripts/benchmark-scenarios.sh list
```

Inject one of the benchmark scenarios:

```bash
./scripts/benchmark-scenarios.sh inject SC2
```

Recover that scenario:

```bash
./scripts/benchmark-scenarios.sh recover SC2
```

Return the demo to a mostly quiet clean slate:

```bash
./scripts/demo-testbed.sh clean-slate
```

`clean-slate` restores the checkout image, removes checkout chaos, stops scenario traffic, and scales the default OTel demo `load-generator` to `0`.

Resume the default demo background traffic later with:

```bash
./scripts/demo-testbed.sh traffic-on
```

### HolmesGPT Benchmark Testing

HolmesGPT is invoked via the local `holmes` CLI for benchmark testing. Configuration:

**Setup (one time):**

1. Extract your Anthropic API key from `~/.holmes/config.yaml`:

```bash
grep ANTHROPIC_API_KEY ~/.holmes/config.yaml
```

2. Run holmes with the configured model (no environment setup needed):

```bash
holmes ask "What services are in the otel-demo namespace?" --no-interactive
```

**Benchmark runs:**

```bash
holmes ask "Your query here" \
  --model="anthropic/claude-haiku-4-5-20251001" \
  --no-interactive \
  --log-costs \
  --json-output-file /tmp/holmes_run.json
```

The `--json-output-file` output contains token counts, tool calls, and results suitable for scoring.

### Validate

```bash
./scripts/demo-testbed.sh validate
```

Validate that the benchmark scenario artifacts are wired correctly:

```bash
./scripts/benchmark-scenarios.sh validate all
```

Checks:

- Causely pods are healthy
- OTel Demo pods are healthy
- Frontend is reachable at `localhost:8080`
- Feature page is reachable at `localhost:8080/feature/`

Stop the local port-forward:

```bash
./scripts/demo-testbed.sh stop-port-forward
```

Remove the demo:

```bash
helm uninstall otel-demo -n otel-demo
kubectl delete ns otel-demo
```

---

## Detailed Controls

### Common Flows

Primary scenario start:

```bash
./scripts/checkout-scenarios.sh scenario-start
```

Benchmark scenario list:

```bash
./scripts/benchmark-scenarios.sh list
```

Benchmark scenario inject:

```bash
./scripts/benchmark-scenarios.sh inject SC2
```

Benchmark scenario recover:

```bash
./scripts/benchmark-scenarios.sh recover SC2
```

Recover every benchmark scenario and clear benchmark state:

```bash
./scripts/benchmark-scenarios.sh reset-all
```

Primary clean-up:

```bash
./scripts/demo-testbed.sh clean-slate
```

Primary clean-up and validation:

```bash
./scripts/demo-testbed.sh clean-slate
./scripts/demo-testbed.sh validate
```

Restore the normal OTel demo background load:

```bash
./scripts/demo-testbed.sh traffic-on
```

### Fine-Grained Recovery Controls

Recover only the checkout application scenario:

```bash
./scripts/checkout-scenarios.sh scenario-recover
```

Remove only the locally managed frontend port-forward:

```bash
./scripts/demo-testbed.sh stop-port-forward
```

Check current scenario and deployed checkout image:

```bash
./scripts/checkout-scenarios.sh status
```

Check benchmark scenario state:

```bash
./scripts/benchmark-scenarios.sh status
```

Check cluster and namespace resource status:

```bash
./scripts/demo-testbed.sh status
```

## Scenario Details

### Benchmark Scenario Dispatcher

The benchmark scenarios live under `benchmark/scenarios/SC1` and `benchmark/scenarios/SC2`, with source patches in `benchmark/patches/`. Scenarios are controlled through `scripts/benchmark-scenarios.sh`.

Commands:

```bash
./scripts/benchmark-scenarios.sh list
./scripts/benchmark-scenarios.sh inject <SCENARIO_ID>
./scripts/benchmark-scenarios.sh recover <SCENARIO_ID>
./scripts/benchmark-scenarios.sh status [SCENARIO_ID]
./scripts/benchmark-scenarios.sh validate all
./scripts/benchmark-scenarios.sh reset-all
```

Available benchmark scenarios:

- `SC1` Application Regression: checkout bundle-index panic (Go source patch + Docker build).
- `SC2` Payment Service Fraud Check Misconfiguration: `FRAUD_RISK_THRESHOLD` constant zeroed out in `charge.js` rejects every transaction, causing cascading `RequestErrorRate_High` on payment, checkout, and frontend (Node.js source patch + Docker build).

### Application Scenario — `checkout-bundle-index-oob`

Start:

```bash
./scripts/checkout-scenarios.sh scenario-start
```

Alias:

```bash
./scripts/checkout-scenarios.sh scenario-start-spurious
```

What it does:

- Modifies `checkout` `PlaceOrder` with a bundle-selection logic regression
- Assumes at least two order items and dereferences `prep.orderItems[1]` unconditionally
- Panics on single-item checkout traffic (`index out of range [1] with length 1`)
- Causes repeated checkout failures and pod restarts under sustained traffic
- Enables Causely Alertmanager ingestion in the running analysis service if needed
- Sends a synthetic alert bundle that maps to `RequestErrorRate_High` on:
- `Service` `otel-demo/checkout`
- `RPCMethod` `oteldemo.CheckoutService/PlaceOrder`
- Repeatedly sends bad requests to `frontend-proxy` so the proxy emits noisy access-log evidence
- Sends a synthetic `FrontendProxyHighRequestErrors` alert mapped to `RequestErrorRate_High` on `Service` `otel-demo/frontend-proxy`
- Useful for demos where you want extra, non-root-cause evidence present alongside the real checkout failure

Validate:

```bash
kubectl -n otel-demo logs deploy/checkout --since=2m --tail=20
```

Look for panic lines similar to:

```text
panic: runtime error: index out of range [1] with length 1
```


Expected signal:

- Elevated request errors on `otel-demo/checkout`
- Elevated request errors on `oteldemo.CheckoutService/PlaceOrder`
- Elevated request errors on `/api/checkout`
- Checkout pod restarts driven by process panics
- `alert_history` rows for:
- `CheckoutServiceHighRequestErrors`
- `CheckoutPlaceOrderHighRPCRequestErrors`
- `FrontendProxyHighRequestErrors`

Recover:

```bash
./scripts/demo-testbed.sh clean-slate
```

### What to Check in Causely

After running the application scenario:

- Symptoms on `otel-demo/checkout`
- Symptoms on `oteldemo.CheckoutService/PlaceOrder`
- Symptoms on `/api/checkout`
- Root cause on `otel-demo/checkout`
- Evidence logs containing panic stack traces for an index-out-of-range in `PlaceOrder`

---

## Causely Topology Wiring

Causely builds its service call graph from OTel trace spans. Without traces reaching Causely, the topology is empty and blast radius on all root causes will be limited to the directly faulted service.

### How it works

`demo-testbed.sh setup` detects whether the `causely` namespace exists and automatically applies `manifests/otel-collector/values-causely-traces.yaml` as a Helm overlay. This adds `otlp_http/causely` as an exporter in the OTel collector's traces pipeline, pointed at `mediator.causely-mediation.svc.cluster.local:54318` — the Causely otel-collector that enriches spans and forwards them to the mediator's embedded OTLP server for topology processing.

### If you deployed otel-demo before Causely

Re-run setup to apply the overlay:

```bash
./scripts/demo-testbed.sh setup
```

Helm upgrade is idempotent — this only changes the collector config, all other services are unaffected.

### Verifying traces are flowing

```bash
./scripts/demo-testbed.sh validate
```

The validate step checks that the collector is reaching `causely-gateway` without connection errors. 
