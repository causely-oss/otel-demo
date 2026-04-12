#!/usr/bin/env bash
set -euo pipefail

SCENARIO_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCENARIO_COMMON_DIR}/../.." && pwd)}"
TMP_DIR="${ROOT_DIR}/.tmp"
BENCHMARK_TMP_DIR="${TMP_DIR}/benchmark"
STATE_DIR="${BENCHMARK_TMP_DIR}/state"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-otel-demo}"
CHAOS_NAMESPACE="${CHAOS_NAMESPACE:-chaos-mesh}"
SRC_DIR="${SRC_DIR:-${ROOT_DIR}/app-src/opentelemetry-demo}"
OTEL_DEMO_REF="${OTEL_DEMO_REF:-2.2.0}"
OTEL_DEMO_REPO="${OTEL_DEMO_REPO:-https://github.com/open-telemetry/opentelemetry-demo.git}"

log() {
  printf '[benchmark] %s\n' "$1" >&2
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

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

state_file() {
  local key="$1"
  printf '%s/%s\n' "$STATE_DIR" "$key"
}

write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  printf '%s' "$value" >"$(state_file "$key")"
}

read_state() {
  local key="$1"
  local file
  file="$(state_file "$key")"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

delete_state() {
  local key="$1"
  rm -f "$(state_file "$key")"
}

scenario_mark_active() {
  local scenario_id="$1"
  ensure_state_dir
  cat >"$(state_file "${scenario_id}.env")" <<EOF
SCENARIO_ID=${scenario_id}
SCENARIO_STATUS=active
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

scenario_mark_inactive() {
  local scenario_id="$1"
  ensure_state_dir
  cat >"$(state_file "${scenario_id}.env")" <<EOF
SCENARIO_ID=${scenario_id}
SCENARIO_STATUS=inactive
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

wait_for_rollout() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-240}"
  kubectl -n "$namespace" rollout status "deployment/${deployment}" --timeout="${timeout}s" >/dev/null
}

get_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  kubectl -n "$namespace" get deployment "$deployment" -o json \
    | jq -r --arg container "$container" '
      .spec.template.spec.containers[]
      | select(.name == $container)
      | .image
    '
}

save_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local state_key="$4"
  if [[ -n "$(read_state "$state_key")" ]]; then
    return 0
  fi
  write_state "$state_key" "$(get_deployment_image "$namespace" "$deployment" "$container")"
}

set_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local image="$4"
  log "Setting ${namespace}/${deployment} image -> ${image}"
  kubectl -n "$namespace" set image "deployment/${deployment}" "${container}=${image}" >/dev/null
  wait_for_rollout "$namespace" "$deployment" 360
}

restore_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local state_key="$4"
  local fallback="${5:-}"
  local image
  image="$(read_state "$state_key")"
  if [[ -z "$image" ]]; then
    image="$fallback"
  fi
  if [[ -z "$image" ]]; then
    echo "No saved image state found for ${state_key}" >&2
    exit 1
  fi
  set_deployment_image "$namespace" "$deployment" "$container" "$image"
  delete_state "$state_key"
}

save_deployment_env() {
  local namespace="$1"
  local deployment="$2"
  local env_name="$3"
  local state_key="$4"
  if [[ -n "$(read_state "$state_key")" ]]; then
    return 0
  fi
  local value
  value="$(kubectl -n "$namespace" get deployment "$deployment" -o json \
    | jq -c --arg env_name "$env_name" '
      first(.spec.template.spec.containers[].env[]? | select(.name == $env_name))
      // null
    ')"
  write_state "$state_key" "$value"
}

patch_deployment_env() {
  local namespace="$1"
  local deployment="$2"
  local env_name="$3"
  local env_value="$4"
  log "Setting ${namespace}/${deployment} env ${env_name}=${env_value}"
  kubectl -n "$namespace" set env "deployment/${deployment}" "${env_name}=${env_value}" >/dev/null
  wait_for_rollout "$namespace" "$deployment" 240
}

restore_deployment_env() {
  local namespace="$1"
  local deployment="$2"
  local env_name="$3"
  local state_key="$4"
  local fallback="${5:-}"
  local saved
  local value
  saved="$(read_state "$state_key")"
  if [[ -z "$saved" ]]; then
    if [[ -n "$fallback" ]]; then
      patch_deployment_env "$namespace" "$deployment" "$env_name" "$fallback"
      return 0
    fi
    echo "No saved env state found for ${state_key}" >&2
    exit 1
  fi
  if [[ "$saved" == "null" ]]; then
    log "Removing ${namespace}/${deployment} env ${env_name}"
    kubectl -n "$namespace" set env "deployment/${deployment}" "${env_name}-" >/dev/null
    wait_for_rollout "$namespace" "$deployment" 240
  else
    value="$(printf '%s' "$saved" | jq -r '.value // empty')"
    patch_deployment_env "$namespace" "$deployment" "$env_name" "$value"
  fi
  delete_state "$state_key"
}

save_deployment_resources() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local state_key="$4"
  if [[ -n "$(read_state "$state_key")" ]]; then
    return 0
  fi
  local resources
  resources="$(kubectl -n "$namespace" get deployment "$deployment" -o json \
    | jq -c --arg container "$container" '
      first(.spec.template.spec.containers[] | select(.name == $container) | .resources)
      // {}
    ')"
  write_state "$state_key" "$resources"
}

patch_deployment_resources() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local resources_json="$4"
  local patch
  patch="$(jq -cn \
    --arg container "$container" \
    --argjson resources "$resources_json" \
    '{spec:{template:{spec:{containers:[{name:$container,resources:$resources}]}}}}')"
  kubectl -n "$namespace" patch deployment "$deployment" --type merge -p "$patch" >/dev/null
  wait_for_rollout "$namespace" "$deployment" 240
}

patch_deployment_memory() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local memory_limit="$4"
  local current_resources
  local patched_resources
  current_resources="$(kubectl -n "$namespace" get deployment "$deployment" -o json \
    | jq -c --arg container "$container" '
      first(.spec.template.spec.containers[] | select(.name == $container) | .resources)
      // {}
    ')"
  patched_resources="$(printf '%s' "$current_resources" | jq -c --arg memory "$memory_limit" '
    (.limits //= {}) |
    (.requests //= {}) |
    .limits.memory = $memory |
    .requests.memory = $memory
  ')"
  log "Patching ${namespace}/${deployment} memory -> ${memory_limit}"
  patch_deployment_resources "$namespace" "$deployment" "$container" "$patched_resources"
}

restore_deployment_resources() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local state_key="$4"
  local resources_json
  resources_json="$(read_state "$state_key")"
  if [[ -z "$resources_json" ]]; then
    echo "No saved resource state found for ${state_key}" >&2
    exit 1
  fi
  log "Restoring ${namespace}/${deployment} resources"
  patch_deployment_resources "$namespace" "$deployment" "$container" "$resources_json"
  delete_state "$state_key"
}

get_flagd_variant() {
  local flag_name="$1"
  kubectl -n "$OTEL_NAMESPACE" get configmap flagd-config -o jsonpath='{.data.demo\.flagd\.json}' \
    | jq -r --arg flag_name "$flag_name" '.flags[$flag_name].defaultVariant'
}

save_flagd_variant() {
  local flag_name="$1"
  local state_key="$2"
  if [[ -n "$(read_state "$state_key")" ]]; then
    return 0
  fi
  write_state "$state_key" "$(get_flagd_variant "$flag_name")"
}

patch_flagd_variant() {
  local flag_name="$1"
  local variant="$2"
  local current_flags
  local patched_flags
  current_flags="$(mktemp)"
  patched_flags="$(mktemp)"

  kubectl -n "$OTEL_NAMESPACE" get configmap flagd-config -o jsonpath='{.data.demo\.flagd\.json}' >"$current_flags"
  jq --arg flag_name "$flag_name" --arg variant "$variant" '
    .flags[$flag_name].defaultVariant = $variant
  ' "$current_flags" >"$patched_flags"

  local payload
  payload="$(jq -Rs . <"$patched_flags")"
  kubectl -n "$OTEL_NAMESPACE" patch configmap flagd-config \
    --type merge \
    -p "{\"data\":{\"demo.flagd.json\":${payload}}}" >/dev/null

  kubectl -n "$OTEL_NAMESPACE" rollout restart deployment/flagd >/dev/null
  wait_for_rollout "$OTEL_NAMESPACE" flagd 240

  rm -f "$current_flags" "$patched_flags"
}

restore_flagd_variant() {
  local flag_name="$1"
  local state_key="$2"
  local fallback="${3:-off}"
  local variant
  variant="$(read_state "$state_key")"
  if [[ -z "$variant" ]]; then
    variant="$fallback"
  fi
  patch_flagd_variant "$flag_name" "$variant"
  delete_state "$state_key"
}

apply_manifest_with_rollout() {
  local manifest="$1"
  local namespace="${2:-$OTEL_NAMESPACE}"
  kubectl apply -f "$manifest" >/dev/null
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    if [[ "$resource" == deployment.apps/* ]]; then
      wait_for_rollout "$namespace" "${resource#deployment.apps/}" 240
    fi
  done < <(kubectl get -f "$manifest" -o name)
}

delete_manifest_with_wait() {
  local manifest="$1"
  local namespace="${2:-$OTEL_NAMESPACE}"
  local resources
  resources="$(kubectl get -f "$manifest" -o name 2>/dev/null || true)"
  kubectl delete -f "$manifest" --ignore-not-found >/dev/null
  if [[ -z "$resources" ]]; then
    return 0
  fi
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    if [[ "$resource" == deployment.apps/* ]]; then
      kubectl -n "$namespace" wait --for=delete "deployment/${resource#deployment.apps/}" --timeout=120s >/dev/null 2>&1 || true
    fi
  done <<<"$resources"
}

apply_traffic() {
  local manifest="$1"
  log "Applying traffic manifest ${manifest}"
  apply_manifest_with_rollout "$manifest" "$OTEL_NAMESPACE"
}

delete_traffic() {
  local manifest="$1"
  log "Deleting traffic manifest ${manifest}"
  delete_manifest_with_wait "$manifest" "$OTEL_NAMESPACE"
}

apply_chaos() {
  local manifest="$1"
  log "Applying chaos manifest ${manifest}"
  apply_manifest_with_rollout "$manifest" "$CHAOS_NAMESPACE"
}

delete_chaos() {
  local manifest="$1"
  log "Deleting chaos manifest ${manifest}"
  delete_manifest_with_wait "$manifest" "$CHAOS_NAMESPACE"
}

emit_alert_bundle() {
  local command="$1"
  log "Emitting alert bundle ${command}"
  "${ROOT_DIR}/scripts/causely-alerts.sh" "$command"
}

ensure_source_repo() {
  if [[ -d "${SRC_DIR}/.git" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$SRC_DIR")"
  log "Cloning OpenTelemetry Demo source (${OTEL_DEMO_REF}) into ${SRC_DIR}"
  git clone --depth 1 --branch "$OTEL_DEMO_REF" "$OTEL_DEMO_REPO" "$SRC_DIR"
}

reset_product_catalog_source() {
  ensure_source_repo
  git -C "$SRC_DIR" checkout -- src/product-catalog/main.go
}

apply_patch_to_product_catalog() {
  local patch_file="$1"
  if [[ ! -f "$patch_file" ]]; then
    echo "Patch file not found: ${patch_file}" >&2
    exit 1
  fi
  git -C "$SRC_DIR" apply "$patch_file"
}

reset_payment_source() {
  ensure_source_repo
  git -C "$SRC_DIR" checkout -- src/payment/charge.js
}

apply_patch_to_payment() {
  local patch_file="$1"
  if [[ ! -f "$patch_file" ]]; then
    echo "Patch file not found: ${patch_file}" >&2
    exit 1
  fi
  git -C "$SRC_DIR" apply "$patch_file"
}

build_and_load_image() {
  local src_root="$1"
  local dockerfile="$2"
  local image="$3"
  local cluster_name="${4:-$KIND_CLUSTER_NAME}"
  log "Building image ${image} from ${dockerfile}"
  (
    cd "$src_root"
    docker build -f "$dockerfile" -t "$image" .
  )
  log "Loading image ${image} into kind cluster ${cluster_name}"
  kind load docker-image "$image" --name "$cluster_name"
}

poll_logs() {
  local namespace="$1"
  local selector="$2"
  local pattern="$3"
  local attempts="${4:-20}"
  local sleep_seconds="${5:-5}"
  local i
  for i in $(seq 1 "$attempts"); do
    if kubectl -n "$namespace" logs -l "$selector" --tail=200 2>/dev/null | grep -Fq "$pattern"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

poll_events() {
  local namespace="$1"
  local pattern="$2"
  local attempts="${3:-20}"
  local sleep_seconds="${4:-5}"
  local i
  for i in $(seq 1 "$attempts"); do
    if kubectl -n "$namespace" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | grep -Fq "$pattern"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}
