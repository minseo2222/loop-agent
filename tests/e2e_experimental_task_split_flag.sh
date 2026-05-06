#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_fake_tools() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
count_file="${FAKE_CODEX_COUNT:?FAKE_CODEX_COUNT is required}"
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
Exercise split task behavior.
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
    printf '\nimplementation\n' >> src/a.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Stub implementation output
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critic

## Split task
- Task 1.1.1: Prepare first child
  - Files: `src/a.txt`
  - Verify: `true`
  - Completion criteria:
    - First child is ready
- Task 1.1.2: Prepare second child
  - Files: `src/b.txt`
  - Verify: `true`
  - Completion criteria:
    - Second child is ready

VERDICT: SPLIT_TASK
OUT
    ;;
  *)
    echo "unexpected fake codex call $count" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$bin_dir/envsubst" "$bin_dir/codex"
}

write_project() {
  local project="$1"
  mkdir -p "$project/.loop-agent" "$project/src"
  printf 'a\n' > "$project/src/a.txt"
  printf 'b\n' > "$project/src/b.txt"
  printf '.loop-agent/\n' > "$project/.gitignore"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

## Phase 1

- [ ] Task 1.1: Parent task
  - Files: `src/a.txt`, `.gitignore`
  - Depends: none
  - Fail count: 0
  - Verify: `true`
  - Completion criteria:
    - [ ] Parent task is complete

- [ ] Task 1.2: Downstream task
  - Files: `src/b.txt`
  - Depends: Task 1.1
  - Fail count: 0
  - Verify: `true`
  - Completion criteria:
    - [ ] Downstream task is complete
MD
  git -C "$project" init -q
  git -C "$project" config core.autocrlf false
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" add src .gitignore
  git -C "$project" commit -q -m "initial"
}

run_loop_once() {
  local project="$1"
  local home_dir="$2"
  local bin_dir="$3"
  local output_file="$4"
  mkdir -p "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  : > "$project/.loop-agent/progress.txt"
  : > "$project/.loop-agent/report.md"
  FAKE_CODEX_COUNT="$project/.loop-agent/fake_codex_count" \
  HOME="$home_dir" \
  PATH="$bin_dir:$PATH" \
  LOOP_ALLOW_DIRTY=1 \
  LOOP_ALLOW_AUTO_TASK_SPLIT="${LOOP_ALLOW_AUTO_TASK_SPLIT:-}" \
  COMMIT_ON_PASS=0 \
  LOOP_EVIDENCE_KEEP_RUNS=0 \
    bash "$ROOT/loop.sh" run --iterations 1 --project "$project" --cli codex > "$output_file" 2>&1 || true
}

assert_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "--- $file ---" >&2
    if [[ -f "$file" ]]; then
      cat "$file" >&2
    else
      echo "missing" >&2
    fi
    fail "expected '$text' in $file"
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "did not expect '$text' in $file"
  fi
}

BIN_DIR="$TMP_DIR/bin"
write_fake_tools "$BIN_DIR"

UNFLAGGED="$TMP_DIR/unflagged"
write_project "$UNFLAGGED"
run_loop_once "$UNFLAGGED" "$TMP_DIR/home-unflagged" "$BIN_DIR" "$TMP_DIR/unflagged.out"
assert_not_contains "$UNFLAGGED/.loop-agent/backlog.md" "Task 1.1.1"
assert_contains "$UNFLAGGED/.loop-agent/backlog.md" "- [ ] Task 1.1: Parent task"
assert_contains "$UNFLAGGED/.loop-agent/events.jsonl" '"mutation_type":"task_split"'
assert_contains "$UNFLAGGED/.loop-agent/events.jsonl" '"outcome":"rejected"'
assert_contains "$UNFLAGGED/.loop-agent/events.jsonl" 'LOOP_ALLOW_AUTO_TASK_SPLIT is not 1'
assert_contains "$UNFLAGGED/.loop-agent/proposals/split_task_loop_1_Task_1.1.md" "Split Task Proposal"

FLAGGED="$TMP_DIR/flagged"
write_project "$FLAGGED"
LOOP_ALLOW_AUTO_TASK_SPLIT=1 run_loop_once "$FLAGGED" "$TMP_DIR/home-flagged" "$BIN_DIR" "$TMP_DIR/flagged.out"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "- [!] Task 1.1: Parent task"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "  - Replaced by: Task 1.1.1, Task 1.1.2"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "- [ ] Task 1.1.1: Prepare first child"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "- [ ] Task 1.1.2: Prepare second child"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "  - Depends: Task 1.1.1"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "- [ ] Task 1.2: Downstream task"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "  - Depends: Task 1.1.2"
assert_contains "$FLAGGED/.loop-agent/backlog.md" "  - Fail count: 0"
assert_contains "$FLAGGED/.loop-agent/events.jsonl" '"mutation_type":"task_split"'
assert_contains "$FLAGGED/.loop-agent/events.jsonl" '"outcome":"accepted"'
assert_contains "$FLAGGED/.loop-agent/evidence/loop-1/split_task_mutation.md" "Outcome: accepted"

python "$ROOT/backlog_manager.py" lint "$FLAGGED/.loop-agent/backlog.md" >/dev/null
