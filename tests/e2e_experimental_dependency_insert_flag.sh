#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_backlog() {
  local path="$1"
  cat > "$path" <<'EOF'
# Backlog

## Phase 1

- [x] Task 1.0: Done task
  - Files: `done.txt`
  - Depends: none
  - Fail count: 0
  - Verify: `true`
  - Completion criteria:
    - [x] Done

- [ ] Task 1.1: Current task
  - Files: `current.txt`
  - Depends: Task 1.0
  - Fail count: 0
  - Verify: `true`
  - Completion criteria:
    - [ ] Current done
EOF
}

write_valid_specs() {
  local path="$1"
  cat > "$path" <<'EOF'
[
  {
    "id": "Task 1.0.1",
    "name": "Prepare dependency",
    "files": ["prep.txt"],
    "verify": ["true"],
    "completion_criteria": ["Prepared"]
  }
]
EOF
}

write_invalid_specs() {
  local path="$1"
  cat > "$path" <<'EOF'
[
  {
    "id": "Task 1.0.2",
    "name": "Invalid dependency",
    "files": [],
    "verify": ["true"],
    "completion_criteria": ["Prepared"]
  }
]
EOF
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  if ! grep -Fq -- "$pattern" "$path"; then
    echo "expected $path to contain: $pattern" >&2
    sed -n '1,160p' "$path" >&2 || true
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$path"; then
    echo "expected $path not to contain: $pattern" >&2
    exit 1
  fi
}

assert_order() {
  local path="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$path" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$path" | head -n 1 | cut -d: -f1)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    echo "expected '$first' before '$second' in $path" >&2
    exit 1
  fi
}

make_fake_gemini() {
  local bin_dir="$1"
  local verdict="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gemini" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
  echo "fake gemini"
  exit 0
fi

count_file="${FAKE_GEMINI_COUNT:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise dependency insertion.

VERDICT: PASS
OUT
    ;;
  2)
    cat <<'OUT'
# Plan Review

## Notes
none

VERDICT: PASS
OUT
    ;;
  3)
    printf '%s\n' "implementation touch" > current.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: fake implementation
OUT
    ;;
  *)
    if [[ "${FAKE_DEPENDENCY_VERDICT:?}" == "valid" ]]; then
      cat <<'OUT'
# Impl Critique

## Dependency insertion
- Task 1.0.1: Prepare dependency
  - Files: `prep.txt`
  - Verify: `true`
  - Completion criteria:
    - [ ] Prepared

VERDICT: DEPENDENCY_INSERT
OUT
    else
      cat <<'OUT'
# Impl Critique

## Dependency insertion
- Task 1.0.2: Invalid dependency
  - Verify: `true`
  - Completion criteria:
    - [ ] Prepared

VERDICT: DEPENDENCY_INSERT
OUT
    fi
    ;;
esac
EOF
  chmod +x "$bin_dir/gemini"
  printf '%s\n' "$verdict" > "$bin_dir/verdict"
}

make_project() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  write_backlog "$project/.loop-agent/backlog.md"
  : > "$project/.loop-agent/progress.txt"
  : > "$project/.loop-agent/report.md"
  printf '%s\n' ".loop-agent/" > "$project/.gitignore"
  (cd "$project" && git init -q && git config user.email test@example.com && git config user.name Test && git add . && git commit -q -m init)
}

run_loop_case() {
  local project="$1"
  local verdict="$2"
  local allow_flag="$3"
  local bin_dir="$TMP_DIR/bin_${verdict}_${allow_flag}"
  make_fake_gemini "$bin_dir" "$verdict"
  FAKE_GEMINI_COUNT="$TMP_DIR/count_${verdict}_${allow_flag}" \
  FAKE_DEPENDENCY_VERDICT="$verdict" \
  PATH="$bin_dir:$PATH" \
  GEMINI_API_KEY="fake" \
  COMMIT_ON_PASS=0 \
  LOOP_VERIFY_TIMEOUT=30 \
  LOOP_ALLOW_AUTO_DEPENDENCY_INSERT="$allow_flag" \
    bash "$ROOT/loop.sh" 1 "$project" gemini >/dev/null 2>&1 || true
}

BACKLOG="$TMP_DIR/backlog.md"
BASELINE="$TMP_DIR/baseline.md"
VALID_SPECS="$TMP_DIR/valid_specs.json"
INVALID_SPECS="$TMP_DIR/invalid_specs.json"
write_backlog "$BACKLOG"
cp "$BACKLOG" "$BASELINE"
write_valid_specs "$VALID_SPECS"
write_invalid_specs "$INVALID_SPECS"

"$PYTHON_BIN" "$ROOT/backlog_manager.py" insert-dependency "$BACKLOG" "Task 1.1" "$VALID_SPECS" "reason" "DEPENDENCY_INSERT" ".loop-agent/evidence/test"
assert_order "$BACKLOG" "- [ ] Task 1.0.1: Prepare dependency" "- [ ] Task 1.1: Current task"
assert_contains "$BACKLOG" '  - Files: `prep.txt`'
assert_contains "$BACKLOG" '  - Verify: `true`'
assert_contains "$BACKLOG" "  - Depends: Task 1.0, Task 1.0.1"
"$PYTHON_BIN" "$ROOT/backlog_manager.py" lint "$BACKLOG" >/dev/null

INVALID_BACKLOG="$TMP_DIR/invalid_backlog.md"
cp "$BASELINE" "$INVALID_BACKLOG"
if "$PYTHON_BIN" "$ROOT/backlog_manager.py" insert-dependency "$INVALID_BACKLOG" "Task 1.1" "$INVALID_SPECS" "reason" "DEPENDENCY_INSERT" ".loop-agent/evidence/test" >/dev/null 2>&1; then
  echo "invalid dependency spec unexpectedly succeeded" >&2
  exit 1
fi
cmp "$BASELINE" "$INVALID_BACKLOG" >/dev/null

assert_contains "$ROOT/loop.sh" "DEPENDENCY_INSERT"
assert_contains "$ROOT/loop.sh" "LOOP_ALLOW_AUTO_DEPENDENCY_INSERT"
assert_contains "$ROOT/loop.sh" "mutation_type=dependency_insert"
assert_contains "$ROOT/loop.sh" "insert-dependency"

UNFLAGGED_PROJECT="$TMP_DIR/project_unflagged"
make_project "$UNFLAGGED_PROJECT"
run_loop_case "$UNFLAGGED_PROJECT" "valid" "0"
assert_not_contains "$UNFLAGGED_PROJECT/.loop-agent/backlog.md" "Task 1.0.1: Prepare dependency"
assert_contains "$UNFLAGGED_PROJECT/.loop-agent/backlog.md" "- [!] Task 1.1: Current task"
assert_contains "$UNFLAGGED_PROJECT/.loop-agent/events.jsonl" '"mutation_type":"dependency_insert"'
assert_contains "$UNFLAGGED_PROJECT/.loop-agent/events.jsonl" '"outcome":"rejected"'

FLAGGED_PROJECT="$TMP_DIR/project_flagged"
make_project "$FLAGGED_PROJECT"
run_loop_case "$FLAGGED_PROJECT" "valid" "1"
assert_contains "$FLAGGED_PROJECT/.loop-agent/backlog.md" "Task 1.0.1: Prepare dependency"
assert_contains "$FLAGGED_PROJECT/.loop-agent/backlog.md" "  - Depends: Task 1.0, Task 1.0.1"
assert_contains "$FLAGGED_PROJECT/.loop-agent/events.jsonl" '"mutation_type":"dependency_insert"'
assert_contains "$FLAGGED_PROJECT/.loop-agent/events.jsonl" '"outcome":"accepted"'
"$PYTHON_BIN" "$ROOT/backlog_manager.py" lint "$FLAGGED_PROJECT/.loop-agent/backlog.md" >/dev/null

INVALID_PROJECT="$TMP_DIR/project_invalid"
make_project "$INVALID_PROJECT"
run_loop_case "$INVALID_PROJECT" "invalid" "1"
assert_not_contains "$INVALID_PROJECT/.loop-agent/backlog.md" "Task 1.0.2: Invalid dependency"
assert_contains "$INVALID_PROJECT/.loop-agent/events.jsonl" '"mutation_type":"dependency_insert"'
assert_contains "$INVALID_PROJECT/.loop-agent/events.jsonl" '"outcome":"rejected"'
"$PYTHON_BIN" "$ROOT/backlog_manager.py" lint "$INVALID_PROJECT/.loop-agent/backlog.md" >/dev/null
