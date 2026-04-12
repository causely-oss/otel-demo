#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/benchmark/lib/scenario-common.sh"

require_cmds git kubectl jq

delete_traffic "$ROOT_DIR/manifests/traffic/otel-demo-checkout-traffic-heavy.yaml"
restore_deployment_image "$OTEL_NAMESPACE" "payment" "payment" "SC2.payment.image"
reset_payment_source
delete_state "SC2.payment.scenario-image"
scenario_mark_inactive "SC2"
