#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCHMARK_DIR="${ROOT_DIR}/benchmark/scenarios"

usage() {
  cat <<'EOF'
Usage: ./scripts/benchmark-scenarios.sh <command> [scenario-id]

Commands:
  list
  inject <scenario-id>
  recover <scenario-id>
  validate <scenario-id|all>
  status [scenario-id]
  reset-all
EOF
}

scenario_dir() {
  local scenario_id="$1"
  printf '%s/%s\n' "$BENCHMARK_DIR" "$scenario_id"
}

require_scenario() {
  local scenario_id="$1"
  local dir
  dir="$(scenario_dir "$scenario_id")"
  if [[ ! -d "$dir" ]]; then
    echo "Unknown scenario: ${scenario_id}" >&2
    exit 1
  fi
}

list_scenarios() {
  local dir
  for dir in "${BENCHMARK_DIR}"/SC*; do
    [[ -d "$dir" ]] || continue
    local scenario_id
    local scenario_name
    scenario_id="$(basename "$dir")"
    scenario_name="$(awk -F': ' '$1 == "name" {print $2; exit}' "$dir/scenario.yaml")"
    printf '%s\t%s\n' "$scenario_id" "$scenario_name"
  done
}

run_script() {
  local scenario_id="$1"
  local action="$2"
  local dir
  dir="$(scenario_dir "$scenario_id")"
  local script="${dir}/${action}.sh"
  if [[ ! -x "$script" ]]; then
    echo "Scenario script is missing or not executable: ${script}" >&2
    exit 1
  fi
  "$script"
}

validate_one() {
  local scenario_id="$1"
  local dir
  dir="$(scenario_dir "$scenario_id")"
  local required=(
    "$dir/scenario.yaml"
    "$dir/inject.sh"
    "$dir/recover.sh"
    "$dir/ground-truth.md"
    "$dir/expected-signals.json"
  )
  local path
  for path in "${required[@]}"; do
    [[ -f "$path" ]] || {
      echo "Missing required artifact: ${path}" >&2
      return 1
    }
  done
  bash -n "$dir/inject.sh"
  bash -n "$dir/recover.sh"
  jq empty "$dir/expected-signals.json" >/dev/null
  printf '%s\tvalid\n' "$scenario_id"
}

print_status() {
  local scenario_id="${1:-}"
  if [[ -n "$scenario_id" ]]; then
    require_scenario "$scenario_id"
    local status_file="${ROOT_DIR}/.tmp/benchmark/state/${scenario_id}.env"
    if [[ -f "$status_file" ]]; then
      cat "$status_file"
    else
      printf 'SCENARIO_ID=%s\nSCENARIO_STATUS=unknown\n' "$scenario_id"
    fi
    return 0
  fi

  local dir
  for dir in "${BENCHMARK_DIR}"/SC*; do
    [[ -d "$dir" ]] || continue
    local id
    id="$(basename "$dir")"
    print_status "$id"
    echo
  done
}

reset_all() {
  local dir
  for dir in "${BENCHMARK_DIR}"/SC*; do
    [[ -d "$dir" ]] || continue
    local scenario_id
    scenario_id="$(basename "$dir")"
    if [[ -x "$dir/recover.sh" ]]; then
      "$dir/recover.sh" || true
    fi
    rm -f "${ROOT_DIR}/.tmp/benchmark/state/${scenario_id}.env"
  done
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)
      list_scenarios
      ;;
    inject)
      require_scenario "${2:-}"
      run_script "$2" inject
      ;;
    recover)
      require_scenario "${2:-}"
      run_script "$2" recover
      ;;
    validate)
      local target="${2:-all}"
      if [[ "$target" == "all" ]]; then
        local dir
        for dir in "${BENCHMARK_DIR}"/SC*; do
          [[ -d "$dir" ]] || continue
          validate_one "$(basename "$dir")"
        done
      else
        require_scenario "$target"
        validate_one "$target"
      fi
      ;;
    status)
      print_status "${2:-}"
      ;;
    reset-all)
      reset_all
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
