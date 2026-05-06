#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "Expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "Did not expect '$unexpected' in $file"
  fi
}

make_backlog() {
  local file="$1"
  local fail_count="$2"
  cat > "$file" <<EOF_BACKLOG
# Backlog

- [ ] Task 1.1: Retry target
  - Depends: none
  - Fail count: $fail_count
  - Completion criteria:
    - [ ] Done
    - [ ] verify: \`true\`
EOF_BACKLOG
}

assert_fail_count() {
  local file="$1"
  local expected="$2"
  assert_contains "$file" "  - Fail count: $expected"
}

assert_pending() {
  local file="$1"
  assert_contains "$file" "- [ ] Task 1.1: Retry target"
}

assert_blocked() {
  local file="$1"
  assert_contains "$file" "- [!] Task 1.1: Retry target"
}

run_fail() {
  local file="$1"
  shift
  "$PYTHON_BIN" "$ROOT/backlog_manager.py" fail "$file" "Task 1.1" "$@"
}

default_backlog="$TMP_DIR/default_backlog.md"
make_backlog "$default_backlog" 0
for expected in 1 2 3 4; do
  output="$(run_fail "$default_backlog")"
  [[ "$output" == "FAIL_COUNT:$expected" ]] || fail "Expected FAIL_COUNT:$expected, got $output"
  assert_fail_count "$default_backlog" "$expected"
  assert_pending "$default_backlog"
done
output="$(run_fail "$default_backlog")"
[[ "$output" == "BLOCKED" ]] || fail "Expected BLOCKED at default max, got $output"
assert_fail_count "$default_backlog" 5
assert_blocked "$default_backlog"

custom_backlog="$TMP_DIR/custom_backlog.md"
make_backlog "$custom_backlog" 2
output="$(run_fail "$custom_backlog" 3)"
[[ "$output" == "BLOCKED" ]] || fail "Expected BLOCKED at custom max, got $output"
assert_fail_count "$custom_backlog" 3
assert_blocked "$custom_backlog"

invalid_backlog="$TMP_DIR/invalid_backlog.md"
make_backlog "$invalid_backlog" 0
set +e
run_fail "$invalid_backlog" 0 > "$TMP_DIR/invalid_manager.out" 2>&1
manager_code=$?
set -e
[[ "$manager_code" -ne 0 ]] || fail "Expected invalid backlog_manager max to fail"
assert_contains "$TMP_DIR/invalid_manager.out" "ERROR: max_attempts must be a positive integer: 0"
assert_fail_count "$invalid_backlog" 0
assert_pending "$invalid_backlog"

assert_contains "$ROOT/loop.sh" 'LOOP_MAX_ATTEMPTS="${LOOP_MAX_ATTEMPTS:-5}"'
assert_contains "$ROOT/loop.sh" 'run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" "$LOOP_MAX_ATTEMPTS"'
assert_contains "$ROOT/loop.sh" '($LOOP_MAX_ATTEMPTS consecutive failures)'

set +e
LOOP_MAX_ATTEMPTS=0 bash "$ROOT/loop.sh" run --iterations 1 --project "$TMP_DIR/missing_project" > "$TMP_DIR/invalid_loop.out" 2>&1
loop_code=$?
set -e
[[ "$loop_code" -ne 0 ]] || fail "Expected invalid LOOP_MAX_ATTEMPTS to fail"
assert_contains "$TMP_DIR/invalid_loop.out" "LOOP_MAX_ATTEMPTS must be a positive integer: 0"
assert_not_contains "$TMP_DIR/invalid_loop.out" "Project folder not found"

echo "PASS: e2e_max_attempts"
