#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/benchmark/lib/scenario-common.sh"

"$ROOT_DIR/scripts/checkout-scenarios.sh" scenario-start
scenario_mark_active "SC1"
