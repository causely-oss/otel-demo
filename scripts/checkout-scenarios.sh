#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp"
STATE_FILE="${TMP_DIR}/scenario-state.env"
LEGACY_STATE_FILE="${TMP_DIR}/real-code-fault-state.env"
SRC_DIR="${SRC_DIR:-${ROOT_DIR}/app-src/opentelemetry-demo}"
PATCH_DIR="${ROOT_DIR}/benchmark/patches/checkout-patches"
TRAFFIC_CHECKOUT_MANIFEST="${ROOT_DIR}/manifests/traffic/otel-demo-checkout-traffic.yaml"
TRAFFIC_FRONTEND_PROXY_SPURIOUS_MANIFEST="${ROOT_DIR}/manifests/traffic/otel-demo-frontend-proxy-spurious-traffic.yaml"
CAUSELY_ALERT_SCRIPT="${ROOT_DIR}/scripts/causely-alerts.sh"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-otel-demo}"
CHECKOUT_DEPLOYMENT="${CHECKOUT_DEPLOYMENT:-checkout}"
CHECKOUT_CONTAINER="${CHECKOUT_CONTAINER:-checkout}"
CHECKOUT_BASE_IMAGE="${CHECKOUT_BASE_IMAGE:-ghcr.io/open-telemetry/demo:2.2.0-checkout}"
OTEL_DEMO_REF="${OTEL_DEMO_REF:-2.2.0}"
OTEL_DEMO_REPO="${OTEL_DEMO_REPO:-https://github.com/open-telemetry/opentelemetry-demo.git}"

usage() {
  cat <<'EOF'
Usage: ./scripts/checkout-scenarios.sh <command>

Commands:
  source-init                     Clone OTel Demo source into app-src/opentelemetry-demo if missing
  source-reset                    Reset local checkout source file to upstream baseline
  scenario-start                  Recommended scenario: checkout bundle-selection logic panic with synthetic frontend-proxy evidence
  scenario-recover                Recover recommended scenario (restore image + stop checkout traffic)
  spurious-evidence-on            Add synthetic frontend-proxy logs and alerts alongside any active scenario
  spurious-evidence-off           Remove synthetic frontend-proxy logs and alerts
  status                          Show active scenario state and checkout image
EOF
}

log() {
  printf '[scenario] %s\n' "$1" >&2
}

require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
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

write_state() {
  local scenario="$1"
  local image="$2"
  ensure_tmp_dir
  cat >"$STATE_FILE" <<EOF
ACTIVE_SCENARIO=${scenario}
ACTIVE_IMAGE=${image}
EOF
}

clear_state() {
  rm -f "$STATE_FILE"
  rm -f "$LEGACY_STATE_FILE"
}

ensure_source_repo() {
  if [[ -d "${SRC_DIR}/.git" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$SRC_DIR")"
  log "Cloning OpenTelemetry Demo source (${OTEL_DEMO_REF}) into ${SRC_DIR}"
  git clone --depth 1 --branch "$OTEL_DEMO_REF" "$OTEL_DEMO_REPO" "$SRC_DIR"
}

reset_checkout_source() {
  ensure_source_repo
  git -C "$SRC_DIR" checkout -- src/checkout/main.go
}

apply_patch_to_checkout() {
  local patch_name="$1"
  local patch_file="${PATCH_DIR}/${patch_name}.patch"
  if [[ ! -f "$patch_file" ]]; then
    echo "Patch file not found: ${patch_file}" >&2
    exit 1
  fi
  git -C "$SRC_DIR" apply "$patch_file"
}

build_checkout_image() {
  local image="$1"
  log "Building checkout image ${image}"
  (
    cd "$SRC_DIR"
    docker build -f src/checkout/Dockerfile -t "$image" .
  )
}

load_image_into_kind() {
  local image="$1"
  log "Loading image into kind cluster ${KIND_CLUSTER_NAME}: ${image}"
  kind load docker-image "$image" --name "$KIND_CLUSTER_NAME"
}

set_checkout_image() {
  local image="$1"
  log "Setting ${CHECKOUT_DEPLOYMENT} image -> ${image}"
  kubectl -n "$OTEL_NAMESPACE" set image "deployment/${CHECKOUT_DEPLOYMENT}" "${CHECKOUT_CONTAINER}=${image}" >/dev/null
  kubectl -n "$OTEL_NAMESPACE" rollout status "deployment/${CHECKOUT_DEPLOYMENT}" --timeout=360s >/dev/null
}

enable_checkout_traffic() {
  log "Ensuring sustained checkout traffic is running"
  kubectl apply -f "$TRAFFIC_CHECKOUT_MANIFEST" >/dev/null
  kubectl -n "$OTEL_NAMESPACE" rollout status deployment/otel-demo-checkout-traffic --timeout=240s >/dev/null
}

disable_checkout_traffic() {
  log "Stopping sustained checkout traffic"
  kubectl delete -f "$TRAFFIC_CHECKOUT_MANIFEST" --ignore-not-found >/dev/null
  kubectl -n "$OTEL_NAMESPACE" wait --for=delete deployment/otel-demo-checkout-traffic --timeout=120s >/dev/null 2>&1 || true
}

enable_frontend_proxy_spurious_traffic() {
  log "Starting synthetic frontend-proxy error traffic"
  kubectl apply -f "$TRAFFIC_FRONTEND_PROXY_SPURIOUS_MANIFEST" >/dev/null
  kubectl -n "$OTEL_NAMESPACE" rollout status deployment/otel-demo-frontend-proxy-spurious-traffic --timeout=240s >/dev/null
}

disable_frontend_proxy_spurious_traffic() {
  log "Stopping synthetic frontend-proxy error traffic"
  kubectl delete -f "$TRAFFIC_FRONTEND_PROXY_SPURIOUS_MANIFEST" --ignore-not-found >/dev/null
  kubectl -n "$OTEL_NAMESPACE" wait --for=delete deployment/otel-demo-frontend-proxy-spurious-traffic --timeout=120s >/dev/null 2>&1 || true
}

emit_checkout_alert_bundle() {
  if [[ ! -x "$CAUSELY_ALERT_SCRIPT" ]]; then
    echo "Alert helper is missing or not executable: ${CAUSELY_ALERT_SCRIPT}" >&2
    exit 1
  fi
  "$CAUSELY_ALERT_SCRIPT" checkout-bundle-bug-on
}

resolve_checkout_alert_bundle() {
  if [[ ! -x "$CAUSELY_ALERT_SCRIPT" ]]; then
    echo "Alert helper is missing or not executable: ${CAUSELY_ALERT_SCRIPT}" >&2
    exit 1
  fi
  "$CAUSELY_ALERT_SCRIPT" checkout-bundle-bug-off
}

emit_frontend_proxy_spurious_alert_bundle() {
  if [[ ! -x "$CAUSELY_ALERT_SCRIPT" ]]; then
    echo "Alert helper is missing or not executable: ${CAUSELY_ALERT_SCRIPT}" >&2
    exit 1
  fi
  "$CAUSELY_ALERT_SCRIPT" frontend-proxy-spurious-on
}

resolve_frontend_proxy_spurious_alert_bundle() {
  if [[ ! -x "$CAUSELY_ALERT_SCRIPT" ]]; then
    echo "Alert helper is missing or not executable: ${CAUSELY_ALERT_SCRIPT}" >&2
    exit 1
  fi
  "$CAUSELY_ALERT_SCRIPT" frontend-proxy-spurious-off
}

start_fault_scenario() {
  local scenario_id="$1"
  local patch_name="$2"
  local include_spurious="${3:-false}"
  ensure_source_repo
  reset_checkout_source
  apply_patch_to_checkout "$patch_name"

  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  local image="otel-local/checkout:${scenario_id}-${ts}"

  build_checkout_image "$image"
  load_image_into_kind "$image"
  set_checkout_image "$image"
  enable_checkout_traffic
  emit_checkout_alert_bundle
  if [[ "$include_spurious" == "true" ]]; then
    enable_frontend_proxy_spurious_traffic
    emit_frontend_proxy_spurious_alert_bundle
  fi
  write_state "$scenario_id" "$image"

  log "Scenario active: ${scenario_id}"
  log "Traffic remains ON until you run a *-recover command."
}

recover_scenario() {
  reset_checkout_source
  set_checkout_image "$CHECKOUT_BASE_IMAGE"
  disable_checkout_traffic
  disable_frontend_proxy_spurious_traffic
  resolve_checkout_alert_bundle
  resolve_frontend_proxy_spurious_alert_bundle
  clear_state
  log "Recovered to base checkout image ${CHECKOUT_BASE_IMAGE}"
}

enable_spurious_evidence() {
  enable_frontend_proxy_spurious_traffic
  emit_frontend_proxy_spurious_alert_bundle
}

disable_spurious_evidence() {
  disable_frontend_proxy_spurious_traffic
  resolve_frontend_proxy_spurious_alert_bundle
}

print_status() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  elif [[ -f "$LEGACY_STATE_FILE" ]]; then
    cat "$LEGACY_STATE_FILE"
  else
    echo "ACTIVE_SCENARIO=none"
    echo "ACTIVE_IMAGE=none"
  fi
  local current_image
  current_image="$(kubectl -n "$OTEL_NAMESPACE" get deployment "$CHECKOUT_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"$CHECKOUT_CONTAINER"'")].image}')"
  echo "DEPLOYED_IMAGE=${current_image}"
}

main() {
  require_cmds git docker kind kubectl
  local cmd="${1:-}"

  case "$cmd" in
    source-init)
      ensure_source_repo
      ;;
    source-reset)
      reset_checkout_source
      ;;
    scenario-start)
      start_fault_scenario "checkout-bundle-index-oob" "bundle-index-oob" "true"
      ;;
    scenario-recover)
      recover_scenario
      ;;
    spurious-evidence-on)
      enable_spurious_evidence
      ;;
    spurious-evidence-off)
      disable_spurious_evidence
      ;;
    status)
      print_status
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
