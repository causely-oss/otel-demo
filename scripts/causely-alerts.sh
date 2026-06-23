#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp"

CAUSELY_NAMESPACE="${CAUSELY_NAMESPACE:-causely}"
OTEL_NAMESPACE="${OTEL_NAMESPACE:-otel-demo}"
MEDIATOR_CONFIGMAP="${MEDIATOR_CONFIGMAP:-mediator}"
MEDIATOR_DEPLOYMENT="${MEDIATOR_DEPLOYMENT:-mediator}"
MEDIATOR_POD_LABEL="${MEDIATOR_POD_LABEL:-app=causely-mediator}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
LOCAL_ALERT_PORT="${LOCAL_ALERT_PORT:-19093}"

CHECKOUT_RPC_SERVICE="${CHECKOUT_RPC_SERVICE:-oteldemo.CheckoutService}"
CHECKOUT_RPC_METHOD="${CHECKOUT_RPC_METHOD:-PlaceOrder}"

CHECKOUT_SERVICE_ALERT_NAME="${CHECKOUT_SERVICE_ALERT_NAME:-CheckoutServiceHighRequestErrors}"
CHECKOUT_RPC_ALERT_NAME="${CHECKOUT_RPC_ALERT_NAME:-CheckoutPlaceOrderHighRPCRequestErrors}"
FRONTEND_PROXY_ALERT_NAME="${FRONTEND_PROXY_ALERT_NAME:-FrontendProxyHighRequestErrors}"
PAYMENT_SERVICE_ALERT_NAME="${PAYMENT_SERVICE_ALERT_NAME:-PaymentServiceHighRequestErrors}"
KAFKA_CONSUMER_LAG_ALERT_NAME="${KAFKA_CONSUMER_LAG_ALERT_NAME:-KafkaConsumerLagHigh}"

PF_PID=""

usage() {
  cat <<'EOF'
Usage: ./scripts/causely-alerts.sh <command>

Commands:
  bootstrap                      Enable Causely Alertmanager ingestion and install demo alert mappings
  checkout-bundle-bug-on         Emit the checkout scenario alert set mapped to request-error symptoms
  checkout-bundle-bug-off        Emit inactive versions of the checkout scenario alert set
  frontend-proxy-spurious-on     Emit a synthetic request-error alert mapped to frontend-proxy
  frontend-proxy-spurious-off    Emit an inactive version of the frontend-proxy synthetic alert
  sc4-messaging-failure-on       Emit fraud-detection and checkout alerts for the messaging failure scenario
  sc4-messaging-failure-off      Emit inactive messaging failure alerts
  sc5-compute-exhaustion-on      Emit checkout alerts for the compute exhaustion scenario
  sc5-compute-exhaustion-off     Emit inactive checkout alerts for the compute exhaustion scenario
EOF
}

log() {
  printf '[causely-alerts] %s\n' "$1" >&2
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

get_mediator_pod() {
  local pod
  pod="$(kubectl -n "$CAUSELY_NAMESPACE" get pods -l "$MEDIATOR_POD_LABEL" -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$pod" ]]; then
    echo "Could not find a mediator pod in namespace ${CAUSELY_NAMESPACE}" >&2
    exit 1
  fi
  printf '%s\n' "$pod"
}

stop_port_forward() {
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" >/dev/null 2>&1; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  PF_PID=""
}

start_port_forward() {
  local pod
  local pf_log
  local code
  ensure_tmp_dir
  pod="$(get_mediator_pod)"
  pf_log="$(mktemp "${TMP_DIR}/causely-alert-port-forward.XXXXXX")"
  kubectl -n "$CAUSELY_NAMESPACE" port-forward "pod/${pod}" "${LOCAL_ALERT_PORT}:${ALERTMANAGER_PORT}" >"$pf_log" 2>&1 &
  PF_PID="$!"

  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LOCAL_ALERT_PORT}/api/v1/alerts" || true)"
    if [[ "$code" == "200" || "$code" == "405" || "$code" == "400" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "Alertmanager endpoint on mediator pod did not become ready. Port-forward log: ${pf_log}" >&2
  stop_port_forward
  exit 1
}

patch_mediator_configmap() {
  ensure_tmp_dir

  local current_json
  local patched_json
  local changed_file
  current_json="$(mktemp "${TMP_DIR}/mediator-config-current.XXXXXX")"
  patched_json="$(mktemp "${TMP_DIR}/mediator-config-patched.XXXXXX")"
  changed_file="$(mktemp "${TMP_DIR}/mediator-config-changed.XXXXXX")"

  kubectl -n "$CAUSELY_NAMESPACE" get configmap "$MEDIATOR_CONFIGMAP" -o json >"$current_json"

  # kubernetes_service discovery resolves entities by namespace+service labels —
  # no postgres service UUID lookup required.
  ruby - "$current_json" "$patched_json" "$changed_file" <<'RUBY'
require "json"
require "yaml"

current_path, patched_path, changed_path = ARGV

configmap = JSON.parse(File.read(current_path))
config_yaml = configmap.dig("data", "config.yaml")
abort("config.yaml not found in configmap") if config_yaml.nil? || config_yaml.empty?

cfg = YAML.safe_load(config_yaml, aliases: true) || {}

svc_mapping = lambda do |alert_name, symptom|
  {
    "alert_name" => alert_name,
    "symptom"    => symptom,
    "entity"     => { "service" => {} },
    "discovery"  => [{ "kubernetes_service" => { "namespace" => "namespace", "service_name" => "service" } }],
  }
end

desired_alert_manager = {
  "enabled" => true,
  "port"    => 9093,
  "alert_mappings" => [
    svc_mapping.call("CheckoutServiceHighRequestErrors",  "RequestErrorRate_High"),
    {
      "alert_name" => "CheckoutPlaceOrderHighRPCRequestErrors",
      "symptom"    => "RequestErrorRate_High",
      "entity"     => { "rpc_method" => { "service_label_key" => "rpc_service", "method_label_key" => "rpc_method" } },
      "discovery"  => [{ "rpc_method" => { "service_label_key" => "rpc_service", "method_label_key" => "rpc_method" } }],
    },
    svc_mapping.call("FrontendProxyHighRequestErrors",    "RequestErrorRate_High"),
    svc_mapping.call("PaymentServiceHighRequestErrors",   "RequestErrorRate_High"),
    svc_mapping.call("KafkaConsumerLagHigh",              "ConsumerLag_High"),
  ],
}

changed = cfg["alert_manager"] != desired_alert_manager
cfg["alert_manager"] = desired_alert_manager if changed

configmap["data"]["config.yaml"] = YAML.dump(cfg)
File.write(patched_path, JSON.generate(configmap))
File.write(changed_path, changed ? "true" : "false")
RUBY

  if [[ "$(cat "$changed_file")" == "true" ]]; then
    log "Updating ${MEDIATOR_CONFIGMAP} to enable alert ingestion and demo alert mappings"
    kubectl replace -f "$patched_json" >/dev/null
    log "Restarting ${MEDIATOR_DEPLOYMENT} to pick up config changes"
    kubectl -n "$CAUSELY_NAMESPACE" rollout restart "deployment/${MEDIATOR_DEPLOYMENT}" >/dev/null
    kubectl -n "$CAUSELY_NAMESPACE" rollout status "deployment/${MEDIATOR_DEPLOYMENT}" --timeout=360s >/dev/null
  else
    log "Alert ingestion config already present"
  fi

  rm -f "$current_json" "$patched_json" "$changed_file"
}

build_checkout_bundle_payload() {
  local alert_state="$1"
  local timestamp="$2"
  local ends_at="$3"
  local rollout_label="$4"
  local summary_suffix="$5"
  local description="$6"
  local severity="$7"
  jq -n \
    --arg alert_state        "$alert_state" \
    --arg service_alert_name "$CHECKOUT_SERVICE_ALERT_NAME" \
    --arg rpc_alert_name     "$CHECKOUT_RPC_ALERT_NAME" \
    --arg namespace          "$OTEL_NAMESPACE" \
    --arg service            "checkout" \
    --arg rpc_service        "$CHECKOUT_RPC_SERVICE" \
    --arg rpc_method         "$CHECKOUT_RPC_METHOD" \
    --arg starts_at          "$timestamp" \
    --arg ends_at            "$ends_at" \
    --arg rollout_label      "$rollout_label" \
    --arg summary_suffix     "$summary_suffix" \
    --arg description        "$description" \
    --arg severity           "$severity" \
    '{
      alerts: [
        {
          labels: {
            alertname:  $service_alert_name,
            severity:   $severity,
            namespace:  $namespace,
            service:    $service,
            rollout:    $rollout_label,
            alertstate: $alert_state
          },
          annotations: {
            summary:     ("Checkout service request errors are elevated" + $summary_suffix),
            description: $description
          },
          startsAt: $starts_at,
          endsAt:   $ends_at
        },
        {
          labels: {
            alertname:   $rpc_alert_name,
            severity:    $severity,
            namespace:   $namespace,
            service:     $service,
            rpc_service: $rpc_service,
            rpc_method:  $rpc_method,
            rollout:     $rollout_label,
            alertstate:  $alert_state
          },
          annotations: {
            summary:     ("Checkout PlaceOrder RPC errors are elevated" + $summary_suffix),
            description: $description
          },
          startsAt: $starts_at,
          endsAt:   $ends_at
        }
      ]
    }'
}

build_service_alert_payload() {
  local alert_state="$1"
  local alert_name="$2"
  local service="$3"
  local timestamp="$4"
  local ends_at="$5"
  local summary="$6"
  local description="$7"
  local severity="$8"
  local extra_labels="${9:-}"
  [[ -n "$extra_labels" ]] || extra_labels="{}"
  jq -n \
    --arg alert_state  "$alert_state" \
    --arg alert_name   "$alert_name" \
    --arg namespace    "$OTEL_NAMESPACE" \
    --arg service      "$service" \
    --arg starts_at    "$timestamp" \
    --arg ends_at      "$ends_at" \
    --arg summary      "$summary" \
    --arg description  "$description" \
    --arg severity     "$severity" \
    --argjson extra_labels "$extra_labels" \
    '{
      alerts: [
        {
          labels: ({
            alertname:  $alert_name,
            severity:   $severity,
            namespace:  $namespace,
            service:    $service,
            alertstate: $alert_state
          } + $extra_labels),
          annotations: {
            summary:     $summary,
            description: $description
          },
          startsAt: $starts_at,
          endsAt:   $ends_at
        }
      ]
    }'
}

combine_payloads() {
  jq -s '{alerts: (map(.alerts // []) | add)}'
}

post_payload() {
  local payload="$1"
  start_port_forward
  trap stop_port_forward EXIT
  curl -fsS -X POST \
    "http://127.0.0.1:${LOCAL_ALERT_PORT}/api/v1/alerts" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null
  stop_port_forward
  trap - EXIT
}

emit_checkout_alert() {
  local state="$1"
  local now ends_at alert_state payload

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ends_at=""
  alert_state="firing"

  if [[ "$state" == "inactive" ]]; then
    ends_at="$now"
    alert_state="inactive"
  fi

  payload="$(
    build_checkout_bundle_payload \
      "$alert_state" \
      "$now" \
      "$ends_at" \
      "bundle-v2" \
      "" \
      "Checkout failures increased after a recent order-processing change in the bundle-selection path. Review recent cart item handling changes affecting single-item orders." \
      "critical"
  )"

  post_payload "$payload"
  log "Sent ${state} checkout scenario alerts"
}

emit_frontend_proxy_alert() {
  local state="$1"
  local now ends_at alert_state payload

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ends_at=""
  alert_state="firing"

  if [[ "$state" == "inactive" ]]; then
    ends_at="$now"
    alert_state="inactive"
  fi

  payload="$(
    build_service_alert_payload \
      "$alert_state" \
      "$FRONTEND_PROXY_ALERT_NAME" \
      "frontend-proxy" \
      "$now" \
      "$ends_at" \
      "Frontend proxy request errors are elevated" \
      "Synthetic scenario evidence: frontend-proxy is serving repeated failing requests that are unrelated to the checkout root cause." \
      "warning" \
      '{"evidence_kind":"spurious"}'
  )"

  post_payload "$payload"
  log "Sent ${state} synthetic frontend-proxy alert"
}

emit_sc4_messaging_failure_alerts() {
  local state="$1"
  local now ends_at alert_state payload

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ends_at=""
  alert_state="firing"

  if [[ "$state" == "inactive" ]]; then
    ends_at="$now"
    alert_state="inactive"
  fi

  payload="$(
    {
      build_service_alert_payload \
        "$alert_state" \
        "$KAFKA_CONSUMER_LAG_ALERT_NAME" \
        "fraud-detection" \
        "$now" \
        "$ends_at" \
        "Fraud detection consumer lag is elevated" \
        "Benchmark scenario: the fraud-detection consumer was disrupted and Kafka-backed work is backing up." \
        "critical" \
        '{"fault_kind":"consumer_disruption"}'
      build_service_alert_payload \
        "$alert_state" \
        "$CHECKOUT_SERVICE_ALERT_NAME" \
        "checkout" \
        "$now" \
        "$ends_at" \
        "Checkout request errors are elevated due to messaging-path disruption" \
        "Benchmark scenario: checkout is degraded while fraud-detection is unavailable." \
        "warning" \
        '{"fault_kind":"messaging"}'
    } | combine_payloads
  )"

  post_payload "$payload"
  log "Sent ${state} SC4 messaging failure alerts"
}

emit_sc5_compute_exhaustion_alerts() {
  emit_checkout_alert "$1"
}

bootstrap() {
  require_cmds kubectl jq ruby curl
  patch_mediator_configmap
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    bootstrap)
      bootstrap
      ;;
    checkout-bundle-bug-on)
      bootstrap
      emit_checkout_alert "active"
      ;;
    checkout-bundle-bug-off)
      bootstrap
      emit_checkout_alert "inactive"
      ;;
    frontend-proxy-spurious-on)
      bootstrap
      emit_frontend_proxy_alert "active"
      ;;
    frontend-proxy-spurious-off)
      bootstrap
      emit_frontend_proxy_alert "inactive"
      ;;
    sc4-messaging-failure-on)
      bootstrap
      emit_sc4_messaging_failure_alerts "active"
      ;;
    sc4-messaging-failure-off)
      bootstrap
      emit_sc4_messaging_failure_alerts "inactive"
      ;;
    sc5-compute-exhaustion-on)
      bootstrap
      emit_sc5_compute_exhaustion_alerts "active"
      ;;
    sc5-compute-exhaustion-off)
      bootstrap
      emit_sc5_compute_exhaustion_alerts "inactive"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
