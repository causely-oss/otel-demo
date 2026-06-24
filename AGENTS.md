# Try Causely With Your Agent

Deploy a realistic microservices environment on your laptop, inject
a real failure, and watch your agent identify root cause using
Causely. No production access needed.

---

## Prerequisites

- `kind`
- `kubectl`
- `helm`
- `jq`
- `curl`
- `uv`

---

## 1. Deploy

Install the Causely mediator from the [welcome page](https://portal.causely.app/welcome). Copy the generated install command and replace `--set mediator.gateway.host=https://gateway.causely.app` with:

```bash
 --set mediator.gateway.host=gw.causely.app 
```

before running it (required for kind and minikube).

<br>

<video src="https://github.com/user-attachments/assets/0b70cae8-0867-48be-a4f4-0abcfb61b3b1" controls width="60%"></video>

<br>


Clone the OTel demo setup for Causely repo:

```bash
git clone https://github.com/causely-oss/otel-demo.git
```

<br>

Clone the source used for scenario builds:

```bash
./scripts/checkout-scenarios.sh source-init
```

<br>

Install the OTel demo:

```bash
./scripts/demo-testbed.sh setup
```

<br>

When setup completes, Causely pods are healthy and the OTel demo
frontend is reachable at `localhost:8080`.

To reach the frontend, start the port-forward:

```bash
kubectl --namespace otel-demo port-forward svc/frontend-proxy 8080:8080
```

> **First install takes 5–10 minutes** — Docker pulls ~20 container images on first run. If the command times out, the pods are likely still starting. Run `kubectl get pods -n otel-demo` to check status and wait for all pods to reach `Running`.

---

## 2. Connect Your Agent via MCP

If you already connected your agent during sandbox setup, skip this step.

See the [MCP Server setup guide](https://docs.causely.ai/agent-integration/mcp-server/) 
for your client — Claude Code, Claude Desktop, Cursor, VS Code, and others are covered.

---

## 3. Inject a Failure

Inject a checkout regression — a bundle optimization that panics
on single-item orders and causes repeated pod restarts:

```bash
./scripts/checkout-scenarios.sh scenario-start
```

---

## 4. Ask Your Agent

Open your agent and run:

> What's wrong in my cluster right now?

Your agent should return the root cause on `otel-demo/checkout`,
the affected services, and evidence from the pod restart logs —
sourced directly from Causely.

---

## 5. Recover

```bash
./scripts/demo-testbed.sh clean-slate
```

---

## Want to go deeper?

See [BENCHMARK.md](./BENCHMARK.md) to run the full scenario suite
and reproduce the published benchmark results.
