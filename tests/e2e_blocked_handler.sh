#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

PROJECT="$TMP/project"
FAKE_BIN="$TMP/bin"
FAKE_STATE_DIR="$TMP/fake_state"
mkdir -p "$PROJECT/.loop-agent" "$FAKE_BIN" "$FAKE_STATE_DIR" "$TMP/home/.codex"

printf '{"tokens":true}\n' > "$TMP/home/.codex/auth.json"
printf 'initial\n' > "$PROJECT/app.txt"
printf '.loop-agent/\n' > "$PROJECT/.gitignore"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" config core.autocrlf false
git -C "$PROJECT" add app.txt .gitignore
git -C "$PROJECT" commit -q -m "initial"

cat > "$PROJECT/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [ ] Task 1.1: Blocked task
  - Description: First task should be blocked.
  - Files: `app.txt`
  - Depends: none
  - Fail count: 0
  - Verify:
    - [ ] verify: `test -f app.txt`
  - Completion criteria:
    - [ ] Blocked handler is exercised.

- [ ] Task 1.2: Next task
  - Description: Second task should be selected after the blocked task.
  - Files: `app.txt`
  - Depends: none
  - Fail count: 0
  - Verify:
    - [ ] verify: `test -f app.txt`
  - Completion criteria:
    - [ ] Next task runs.
BACKLOG

PYTHON_BIN="${PYTHON:-python}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN="python3"
fi

"$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$PROJECT/.loop-agent/backlog.md" > "$TMP/semantic_before.json"

cat > "$FAKE_BIN/codex" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null
count_file="$FAKE_STATE_DIR/codex_count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$((count % 4))" in
  1)
    cat <<'OUT'
# Plan

## Tasks
None.
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
    task_id="$(grep -m1 '^Task ID:' .loop-agent/current_task.md | sed 's/^Task ID: //')"
    printf '%s\n' "$task_id" >> "$FAKE_STATE_DIR/selected_tasks.log"
    if [[ "$task_id" == "Task 1.1" ]]; then
      printf 'blocked edit\n' > app.txt
    else
      printf 'task two edit\n' > app.txt
    fi
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Fake implementation.
OUT
    ;;
  0)
    task_id="$(grep -m1 '^Task ID:' .loop-agent/current_task.md | sed 's/^Task ID: //')"
    if [[ "$task_id" == "Task 1.1" ]]; then
      cat <<'OUT'
# Implementation Critique

## Notes
External dependency is unavailable.

VERDICT: BLOCKED
OUT
    else
      cat <<'OUT'
# Implementation Critique

## Notes
none

VERDICT: PASS
OUT
    fi
    ;;
esac
CODEX
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TMP/home"
export FAKE_STATE_DIR
export COMMIT_ON_PASS=1
export LOOP_VERIFY_TIMEOUT=30

before_commits="$(git -C "$PROJECT" rev-list --count HEAD)"
if "$ROOT/loop.sh" run --iterations 1 --project "$PROJECT" --cli codex > "$TMP/first_run.out" 2>&1; then
  echo "Expected first run to exit nonzero after a BLOCKED-only loop"
  cat "$TMP/first_run.out"
  exit 1
fi
after_block_commits="$(git -C "$PROJECT" rev-list --count HEAD)"
if [[ "$after_block_commits" != "$before_commits" ]]; then
  echo "Blocked run created a commit"
  cat "$TMP/first_run.out"
  exit 1
fi

if [[ "$(cat "$PROJECT/app.txt")" != "initial" ]]; then
  echo "Blocked implementation change was not rolled back"
  exit 1
fi

"$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$PROJECT/.loop-agent/backlog.md" > "$TMP/semantic_after_block.json"
if ! cmp -s "$TMP/semantic_before.json" "$TMP/semantic_after_block.json"; then
  echo "Semantic fields changed when blocking the task"
  diff -u "$TMP/semantic_before.json" "$TMP/semantic_after_block.json" || true
  exit 1
fi

grep -q '^- \[!\] Task 1.1: Blocked task' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Blocked reason: External dependency is unavailable\.' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Last verdict: BLOCKED' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Evidence path: \.loop-agent/evidence/loop-1/' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Description: First task should be blocked\.' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Files: `app.txt`' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Depends: none' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Verify:' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Completion criteria:' "$PROJECT/.loop-agent/backlog.md"
test -f "$PROJECT/.loop-agent/evidence/loop-1/blocked_reason.md"

"$ROOT/loop.sh" run --iterations 1 --project "$PROJECT" --cli codex > "$TMP/second_run.out" 2>&1

if ! grep -qx 'Task 1.1' "$FAKE_STATE_DIR/selected_tasks.log"; then
  echo "First task was not selected by the first run"
  cat "$FAKE_STATE_DIR/selected_tasks.log"
  exit 1
fi
if ! tail -n 1 "$FAKE_STATE_DIR/selected_tasks.log" | grep -qx 'Task 1.2'; then
  echo "Second run did not skip the blocked task"
  cat "$FAKE_STATE_DIR/selected_tasks.log"
  exit 1
fi

if [[ "$(git -C "$PROJECT" log --format=%s --grep='loop-agent: PASS Task 1.1' | wc -l | tr -d ' ')" != "0" ]]; then
  echo "Blocked task was committed as PASS"
  exit 1
fi

grep -q '^- \[!\] Task 1.1: Blocked task' "$PROJECT/.loop-agent/backlog.md"
grep -q '^  - Last verdict: BLOCKED' "$PROJECT/.loop-agent/backlog.md"

echo "PASS"
