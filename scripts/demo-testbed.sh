#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp"
PF_PID_FILE="${TMP_DIR}/frontend-port-forward.pid"
PF_LOG_FILE="${TMP_DIR}/frontend-port-forward.log"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
CAUSELY_NAMESPACE="${CAUSELY_NAMESPACE:-causely}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-otel-demo}"
CHAOS_NAMESPACE="${CHAOS_NAMESPACE:-chaos-mesh}"
OTEL_RELEASE="${OTEL_RELEASE:-otel-demo}"
CHAOS_RELEASE="${CHAOS_RELEASE:-chaos-mesh}"
CHAOS_MANIFEST="${ROOT_DIR}/manifests/chaos/otel-demo-checkout-pod-kill.yaml"
CHECKOUT_SCENARIOS_SCRIPT="${ROOT_DIR}/scripts/checkout-scenarios.sh"
LOAD_GENERATOR_DEPLOYMENT="${LOAD_GENERATOR_DEPLOYMENT:-load-generator}"
VALIDATION_PF_PID=""

usage() {
  cat <<'EOF'
Usage: ./scripts/demo-testbed.sh <command>

Commands:
  setup                    Create/reuse kind cluster, deploy OTel Demo, install Chaos Mesh
                           Leaves load-generator scaled to 0 (quiet by default).
                           Run 'traffic-on' to resume load or 'inject <scenario>' to start a benchmark run.
                           If the 'causely' namespace exists at setup time, automatically
                           applies manifests/otel-collector/values-causely-traces.yaml to
                           wire the OTel collector to export traces to mediator.causely-mediation:54318.
                           Without Causely, deploys in baseline mode (no trace export to Causely).
  start-port-forward       Expose OTel Demo frontend on localhost:8080
  stop-port-forward        Stop frontend port-forward
  chaos-on                 Apply checkout PodChaos experiment
  chaos-off                Delete checkout PodChaos experiment, wait for recovery, and quiet default demo traffic
  clean-slate              Restore checkout, remove chaos, and quiet default demo traffic
  full-reset               Recover all benchmark scenarios, restore checkout, remove chaos, and resume background traffic
  traffic-on               Restore the default OTel demo load-generator replica count
  validate                 Validate pod health, localhost checks, telemetry flow, chaos apply/revert
                           When Causely is present, also verifies mediator.causely-mediation:54318 is reachable.
  status                   Print key namespace resources
EOF
}

log() {
  printf '[testbed] %s\n' "$1"
}

require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

ensure_tmp_dir() {
  mkdir -p "$TMP_DIR"
}

ensure_state_file() {
  ensure_tmp_dir
  touch "${TMP_DIR}/testbed-state.env"
}

state_get() {
  local key="$1"
  ensure_state_file
  grep -E "^${key}=" "${TMP_DIR}/testbed-state.env" | head -n1 | cut -d'=' -f2- || true
}

state_set() {
  local key="$1"
  local value="$2"
  local tmp_file
  ensure_state_file
  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (updated == 0) {
        print key "=" value
      }
    }
  ' "${TMP_DIR}/testbed-state.env" >"$tmp_file"
  mv "$tmp_file" "${TMP_DIR}/testbed-state.env"
}

state_delete() {
  local key="$1"
  local tmp_file
  ensure_state_file
  tmp_file="$(mktemp)"
  grep -Ev "^${key}=" "${TMP_DIR}/testbed-state.env" >"$tmp_file" || true
  mv "$tmp_file" "${TMP_DIR}/testbed-state.env"
}

get_deployment_replicas() {
  local deployment="$1"
  kubectl -n "$OTEL_NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}'
}

save_original_replicas_if_missing() {
  local state_key="$1"
  local deployment="$2"
  local existing
  existing="$(state_get "$state_key")"
  if [[ -n "$existing" ]]; then
    return 0
  fi
  local current
  current="$(get_deployment_replicas "$deployment")"
  if [[ -n "$current" ]]; then
    state_set "$state_key" "$current"
  fi
}

set_deployment_replicas() {
  local deployment="$1"
  local replicas="$2"
  kubectl -n "$OTEL_NAMESPACE" scale "deployment/${deployment}" --replicas="$replicas" >/dev/null
  kubectl -n "$OTEL_NAMESPACE" rollout status "deployment/${deployment}" --timeout=240s >/dev/null
}

ensure_helm_repos() {
  log "Ensuring Helm repos are configured"
  if ! helm repo list | awk 'NR>1 {print $1}' | grep -qx "open-telemetry"; then
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
  fi
  helm repo update >/dev/null
}

deploy_otel_demo() {
  log "Deploying OpenTelemetry Demo into namespace '${OTEL_NAMESPACE}'"
  kubectl create namespace "$OTEL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local helm_args=(
    upgrade --install "$OTEL_RELEASE" open-telemetry/opentelemetry-demo
    --namespace "$OTEL_NAMESPACE"
    --create-namespace
    --wait
    --timeout 15m
  )

  helm "${helm_args[@]}"
}


start_port_forward() {
  ensure_tmp_dir
  log "Starting port-forward from svc/frontend-proxy to localhost:8080"

  if [[ -f "$PF_PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PF_PID_FILE")"
    if kill -0 "$old_pid" >/dev/null 2>&1; then
      log "Port-forward already running (pid=${old_pid})"
      return 0
    fi
    rm -f "$PF_PID_FILE"
  fi

  nohup kubectl -n "$OTEL_NAMESPACE" port-forward svc/frontend-proxy 8080:8080 >"$PF_LOG_FILE" 2>&1 &
  echo "$!" >"$PF_PID_FILE"

  for _ in $(seq 1 20); do
    if curl -fsS "http://localhost:8080/" >/dev/null 2>&1; then
      log "Frontend is reachable at http://localhost:8080/"
      return 0
    fi
    sleep 1
  done

  echo "Port-forward did not become ready; see ${PF_LOG_FILE}" >&2
  return 1
}

stop_port_forward() {
  if [[ ! -f "$PF_PID_FILE" ]]; then
    log "No managed port-forward pid file found"
    return 0
  fi

  local pid
  pid="$(cat "$PF_PID_FILE")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid"
    log "Stopped port-forward pid=${pid}"
  else
    log "Port-forward process already stopped"
  fi
  rm -f "$PF_PID_FILE"
}

quiesce_background_traffic() {
  local current
  current="$(get_deployment_replicas "$LOAD_GENERATOR_DEPLOYMENT")"
  if [[ "$current" == "0" ]]; then
    log "Default demo traffic is already quiet"
    return 0
  fi
  save_original_replicas_if_missing "load_generator_replicas" "$LOAD_GENERATOR_DEPLOYMENT"
  log "Scaling ${LOAD_GENERATOR_DEPLOYMENT} to 0 replicas to quiet background traffic"
  set_deployment_replicas "$LOAD_GENERATOR_DEPLOYMENT" "0"
}

resume_background_traffic() {
  local original
  original="$(state_get "load_generator_replicas")"
  if [[ -z "$original" ]]; then
    original="1"
  fi
  log "Restoring ${LOAD_GENERATOR_DEPLOYMENT} to ${original} replicas"
  set_deployment_replicas "$LOAD_GENERATOR_DEPLOYMENT" "$original"
  state_delete "load_generator_replicas"
}

clean_slate() {
  if [[ ! -x "$CHECKOUT_SCENARIOS_SCRIPT" ]]; then
    echo "Checkout scenarios helper is missing or not executable: ${CHECKOUT_SCENARIOS_SCRIPT}" >&2
    exit 1
  fi
  log "Restoring checkout scenario state"
  "$CHECKOUT_SCENARIOS_SCRIPT" scenario-recover
  revert_chaos
  quiesce_background_traffic
  restart_otel_pods
}

# Restart all otel-demo deployments except flagd.
# flagd is excluded because a simultaneous restart causes all EventStream clients
# to reconnect at once, producing a reconnection storm that Causely detects as a
# root cause and takes several minutes to clear.
restart_otel_pods() {
  log "Restarting otel-demo deployments (excluding flagd) to clear stale pod state"
  local deployments
  deployments=$(kubectl get deployments -n "$OTEL_NAMESPACE" --no-headers \
    -o custom-columns=NAME:.metadata.name | grep -v '^flagd$')
  for dep in $deployments; do
    kubectl rollout restart "deployment/${dep}" -n "$OTEL_NAMESPACE" >/dev/null
  done
  log "Waiting for rollout to complete"
  kubectl rollout status deployment -n "$OTEL_NAMESPACE" --timeout=240s
}

full_reset() {
  log "Running full reset: recovering all benchmark scenarios and restoring demo to clean baseline"
  "${ROOT_DIR}/scripts/benchmark-scenarios.sh" reset-all
  clean_slate
  resume_background_traffic
  log "Full reset complete — environment is clean with background traffic restored"
}

check_namespace_pods_ready() {
  local namespace="$1"
  log "Checking pods in namespace '${namespace}'"
  kubectl get namespace "$namespace" >/dev/null

  local deadline
  deadline=$((SECONDS + 300))

  while true; do
    local pods_json
    pods_json="$(kubectl get pods -n "$namespace" -o json)"

    local pod_count
    pod_count="$(printf '%s' "$pods_json" | jq '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")] | length')"
    if [[ "$pod_count" -eq 0 ]]; then
      echo "No active pods found in namespace ${namespace}" >&2
      return 1
    fi

    local not_ready
    not_ready="$(printf '%s' "$pods_json" | jq -r '
      .items[]
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0)
      | .metadata.name
    ')"

    if [[ -z "$not_ready" ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for Ready pods in namespace ${namespace}. Non-ready pods:" >&2
      echo "$not_ready" >&2
      kubectl get pods -n "$namespace" -o wide
      return 1
    fi

    sleep 5
  done
}

check_frontend_endpoints() {
  log "Checking frontend endpoint http://localhost:8080/"
  curl -fsS "http://localhost:8080/" >/dev/null

  log "Checking feature flag UI endpoint http://localhost:8080/feature/"
  curl -fsS "http://localhost:8080/feature/" >/dev/null
}

ensure_frontend_for_validation() {
  if curl -fsS "http://localhost:8080/" >/dev/null 2>&1; then
    return 0
  fi

  ensure_tmp_dir
  log "No active localhost:8080 frontend detected; starting temporary port-forward for validation"
  kubectl -n "$OTEL_NAMESPACE" port-forward svc/frontend-proxy 8080:8080 >"$PF_LOG_FILE" 2>&1 &
  VALIDATION_PF_PID="$!"

  for _ in $(seq 1 20); do
    if curl -fsS "http://localhost:8080/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Temporary validation port-forward did not become ready. See ${PF_LOG_FILE}" >&2
  return 1
}

cleanup_validation_port_forward() {
  if [[ -n "$VALIDATION_PF_PID" ]]; then
    kill "$VALIDATION_PF_PID" >/dev/null 2>&1 || true
    VALIDATION_PF_PID=""
  fi
}

check_telemetry_flow() {
  log "Checking OTel collector logs for active telemetry export"

  local collector_pods
  collector_pods="$(kubectl get pods -n "$OTEL_NAMESPACE" -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  if [[ -z "$collector_pods" ]]; then
    echo "No opentelemetry-collector pods found in namespace ${OTEL_NAMESPACE}" >&2
    return 1
  fi

  local traces_seen=0
  local metrics_seen=0
  local logs_seen=0
  local causely_errors=0
  local checked_pods=0

  for pod in $collector_pods; do
    checked_pods=$((checked_pods + 1))
    local pod_logs
    pod_logs="$(kubectl logs -n "$OTEL_NAMESPACE" "$pod" --since=2m 2>/dev/null || true)"

    if grep -q '"otelcol.signal": "traces"' <<<"$pod_logs"; then
      traces_seen=1
    fi
    if grep -q '"otelcol.signal": "metrics"' <<<"$pod_logs"; then
      metrics_seen=1
    fi
    if grep -q '"otelcol.signal": "logs"' <<<"$pod_logs"; then
      logs_seen=1
    fi
    if grep -q "causely-gateway" <<<"$pod_logs" && \
       grep -qE "(connection refused|failed to export|rpc error|Unavailable)" <<<"$pod_logs"; then
      causely_errors=1
    fi
  done

  if [[ "$traces_seen" -eq 0 && "$metrics_seen" -eq 0 && "$logs_seen" -eq 0 ]]; then
    echo "No recent telemetry export lines found in ${checked_pods} collector pod logs." >&2
    return 1
  fi

  log "Collector export signals seen: traces=${traces_seen}, metrics=${metrics_seen}, logs=${logs_seen}"

  if kubectl get namespace "$CAUSELY_NAMESPACE" >/dev/null 2>&1; then
    if [[ "$causely_errors" -eq 1 ]]; then
      echo "OTel collector is failing to reach mediator.causely-mediation:54318 — Causely will have no topology data. Check that Causely is running and the mediator service is reachable." >&2
      return 1
    fi
    log "Causely trace export: mediator:54318 reachable, no export errors detected"
  fi
}

validate() {
  ensure_frontend_for_validation
  trap cleanup_validation_port_forward RETURN
  check_namespace_pods_ready "$CAUSELY_NAMESPACE"
  check_namespace_pods_ready "$OTEL_NAMESPACE"
  check_frontend_endpoints
  check_telemetry_flow
  log "Validation passed"
}

status() {
  log "Current context: $(kubectl config current-context)"
  kubectl get ns "$CAUSELY_NAMESPACE" "$OTEL_NAMESPACE" "$CHAOS_NAMESPACE" 2>/dev/null || true
  kubectl get pods -n "$CAUSELY_NAMESPACE" || true
  kubectl get pods -n "$OTEL_NAMESPACE" || true
  kubectl get pods -n "$CHAOS_NAMESPACE" || true
  kubectl -n "$OTEL_NAMESPACE" get deploy otel-demo-checkout-traffic 2>/dev/null || true
}

main() {
  require_cmds kind kubectl helm jq curl
  local command="${1:-}"

  case "$command" in
    setup)
      ensure_helm_repos
      deploy_otel_demo
      quiesce_background_traffic
      ;;
    start-port-forward)
      start_port_forward
      ;;
    stop-port-forward)
      stop_port_forward
      ;;
    clean-slate)
      clean_slate
      ;;
    full-reset)
      full_reset
      ;;
    traffic-on)
      resume_background_traffic
      ;;
    validate)
      validate
      ;;
    status)
      status
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
