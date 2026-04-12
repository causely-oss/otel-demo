#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/benchmark/lib/scenario-common.sh"

require_cmds git docker kind kubectl jq

PAYMENT_SRC="$ROOT_DIR/app-src/opentelemetry-demo"
PATCH_FILE="$ROOT_DIR/benchmark/patches/payment-patches/charge-fraud-check-misconfiguration.patch"
SCENARIO_IMAGE="otel-local/payment:sc2-$(date +%Y%m%d%H%M%S)"

ensure_source_repo
save_deployment_image "$OTEL_NAMESPACE" "payment" "payment" "SC2.payment.image"
reset_payment_source
apply_patch_to_payment "$PATCH_FILE"
build_and_load_image "$PAYMENT_SRC" "src/payment/Dockerfile" "$SCENARIO_IMAGE" "${KIND_CLUSTER_NAME:-kind}"
set_deployment_image "$OTEL_NAMESPACE" "payment" "payment" "$SCENARIO_IMAGE"
apply_traffic "$ROOT_DIR/manifests/traffic/otel-demo-checkout-traffic-heavy.yaml"
write_state "SC2.payment.scenario-image" "$SCENARIO_IMAGE"
scenario_mark_active "SC2"
