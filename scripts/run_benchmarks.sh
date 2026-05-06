#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_FILE="${1:-}"
TEMP_DIR="$(mktemp -d)"
PYTHON=""

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [ -z "$RESULT_FILE" ]; then
  RESULT_FILE="$TEMP_DIR/results.jsonl"
fi

: > "$RESULT_FILE"

if python3 -c 'import json' >/dev/null 2>&1; then
  PYTHON="python3"
elif python -c 'import json' >/dev/null 2>&1; then
  PYTHON="python"
else
  echo "python is required" >&2
  exit 1
fi

json_string() {
  "$PYTHON" -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

find_fixtures() {
  local roots=(
    "$ROOT_DIR/benchmarks/fixtures"
    "$ROOT_DIR/tests/benchmarks/fixtures"
    "$ROOT_DIR/tests/fixtures/benchmarks"
  )
  local root

  for root in "${roots[@]}"; do
    if [ -d "$root" ]; then
      find "$root" -mindepth 1 -maxdepth 1 -type d | sort
      return
    fi
  done

  find "$ROOT_DIR" \
    -path "$ROOT_DIR/.git" -prune -o \
    -path "$ROOT_DIR/.loop-agent" -prune -o \
    -type f -path '*/.loop-agent/backlog.md' -print | sed 's#/.loop-agent/backlog.md$##'

  find "$ROOT_DIR" \
    -path "$ROOT_DIR/.git" -prune -o \
    -path "$ROOT_DIR/.loop-agent" -prune -o \
    -type d -name 'benchmark-*' -print | sort
}

make_fake_cli() {
  local fake_bin="$1"
  local cli

  mkdir -p "$fake_bin"
  for cli in codex gemini claude opencode; do
    cat > "$fake_bin/$cli" <<'EOF'
#!/usr/bin/env bash
echo "fake provider cli: $(basename "$0") $*" >&2
echo "# Implementation Summary"
echo "VERDICT: PASS"
exit 0
EOF
    chmod +x "$fake_bin/$cli"
  done
}

run_loop_agent() {
  if [ -f "$ROOT_DIR/loop.sh" ]; then
    bash "$ROOT_DIR/loop.sh"
  elif [ -f "$ROOT_DIR/loop-agent.sh" ]; then
    bash "$ROOT_DIR/loop-agent.sh"
  elif command -v loop-agent >/dev/null 2>&1; then
    loop-agent
  else
    echo "loop-agent entrypoint not found" >&2
    return 127
  fi
}

has_pass_evidence() {
  local work_dir="$1"

  if [ -f "$work_dir/.loop-agent/events.jsonl" ] && grep -Eq 'PASS|pass' "$work_dir/.loop-agent/events.jsonl"; then
    return 0
  fi

  if [ -f "$work_dir/.loop-agent/backlog.md" ] && grep -Eq '\[[xX]\]' "$work_dir/.loop-agent/backlog.md"; then
    return 0
  fi

  return 1
}

record_result() {
  local scenario="$1"
  local exit_code="$2"
  local committed="$3"
  local false_pass="$4"
  local log_file="$5"
  local scenario_json
  local log_json

  scenario_json="$(printf '%s' "$scenario" | json_string)"
  log_json="$(printf '%s' "$log_file" | json_string)"
  printf '{"scenario":%s,"exit_code":%s,"committed":%s,"false_pass":%s,"log":%s}\n' \
    "$scenario_json" "$exit_code" "$committed" "$false_pass" "$log_json" >> "$RESULT_FILE"
}

mapfile -t FIXTURES < <(find_fixtures)

if [ "${#FIXTURES[@]}" -eq 0 ]; then
  echo "No benchmark fixtures found" >&2
  exit 1
fi

echo "Using fake provider CLIs only"

for fixture in "${FIXTURES[@]}"; do
  scenario="$(basename "$fixture")"
  work_dir="$TEMP_DIR/work/$scenario"
  fake_bin="$TEMP_DIR/fake-bin/$scenario"
  log_file="$TEMP_DIR/logs/$scenario.log"
  exit_code=0
  initial_count=0
  final_count=0
  committed=false
  false_pass=false

  mkdir -p "$work_dir" "$(dirname "$log_file")"
  cp -R "$fixture"/. "$work_dir"/

  (
    cd "$work_dir" || exit 1
    git init -q
    git config user.email "benchmark@example.invalid"
    git config user.name "Benchmark Runner"
    git add .
    if ! git diff --cached --quiet; then
      git commit -qm "Initial benchmark fixture"
    fi
  )

  initial_count="$(git -C "$work_dir" rev-list --count HEAD 2>/dev/null || printf '0')"
  make_fake_cli "$fake_bin"

  (
    cd "$work_dir" || exit 1
    export PATH="$fake_bin:$PATH"
    export CODEX_HOME="$TEMP_DIR/codex-home/$scenario"
    export GEMINI_API_KEY="fake"
    export OPENAI_API_KEY="fake"
    export LOOP_AGENT_FAKE_CLI="1"
    run_loop_agent
  ) > "$log_file" 2>&1
  exit_code=$?

  final_count="$(git -C "$work_dir" rev-list --count HEAD 2>/dev/null || printf '0')"
  if [ "$final_count" -gt "$initial_count" ]; then
    committed=true
  fi

  if [ "$exit_code" -eq 0 ] && [ "$committed" = false ] && has_pass_evidence "$work_dir"; then
    false_pass=true
  fi

  record_result "$scenario" "$exit_code" "$committed" "$false_pass" "$log_file"
  echo "Scenario result: $scenario exit_code=$exit_code committed=$committed false_pass=$false_pass"
done

"$PYTHON" "$ROOT_DIR/scripts/benchmark_report.py" "$RESULT_FILE"
