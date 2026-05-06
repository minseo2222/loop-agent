#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/tests/lib/project_factory.sh"

PROJECT_DIR="$(create_temp_split_task_project)"
cleanup() {
  rm -rf "$PROJECT_DIR"
}
trap cleanup EXIT

[[ -f "$PROJECT_DIR/.loop-agent/backlog.md" ]] || {
  echo "missing .loop-agent/backlog.md" >&2
  exit 1
}
[[ -f "$PROJECT_DIR/src/app.txt" ]] || {
  echo "missing src/app.txt" >&2
  exit 1
}

PYTHON_BIN="${PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if PYTHON_PATH="$(command -v python3 2>/dev/null)" && [[ "$PYTHON_PATH" != *"WindowsApps"* ]]; then
    PYTHON_BIN="python3"
  elif PYTHON_PATH="$(command -v python 2>/dev/null)" && [[ "$PYTHON_PATH" != *"WindowsApps"* ]]; then
    PYTHON_BIN="python"
  else
    echo "python not found" >&2
    exit 1
  fi
fi

json_get() {
  "$PYTHON_BIN" -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], "") or "")' "$1"
}

task_fail_count() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import re
import sys

path, task_id = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
pattern = re.compile(r"^- \[[ x!]\] " + re.escape(task_id) + r":[\s\S]*?(?=\n- \[[ x!]\] Task |\n## |\Z)", re.M)
match = pattern.search(text)
if not match:
    print("__MISSING__")
    sys.exit(0)
fail = re.findall(r"  - Fail count:\s*(\d+)", match.group(0))
print(fail[-1] if fail else "0")
PY
}

assert_no_task_children() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import re
import sys

path, task_id = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
pattern = re.compile(r"^- \[[ x!]\] " + re.escape(task_id) + r"\.\d+:", re.M)
matches = pattern.findall(text)
if matches:
    print("child tasks were inserted into backlog", file=sys.stderr)
    sys.exit(1)
PY
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F -- "$needle" "$file" >/dev/null; then
    echo "missing expected text in $file: $needle" >&2
    exit 1
  fi
}

assert_split_task_block_event() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import json
import sys

path, task_id = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8", errors="replace") as f:
    events = [json.loads(line) for line in f if line.strip()]

for event in events:
    if event.get("event") != "blocked" and event.get("type") != "blocked":
        continue
    if event.get("outcome") != "BLOCKED":
        continue
    if event.get("task_id") != task_id:
        continue
    if event.get("block_type") != "SPLIT_TASK":
        continue
    if not event.get("reason"):
        continue
    if not event.get("suggested_child_task_count"):
        continue
    break
else:
    print("missing required SPLIT_TASK blocked event", file=sys.stderr)
    sys.exit(1)
PY
}

export LOOP_FAKE_PROJECT_DIR="$PROJECT_DIR"
export LOOP_FAKE_SCENARIO=split_task
export PATH="$REPO_ROOT/tests/fake_cli:$PATH"

codex --self-test >/dev/null

BACKLOG="$PROJECT_DIR/.loop-agent/backlog.md"
NEXT_JSON="$("$PYTHON_BIN" "$REPO_ROOT/backlog_manager.py" next "$BACKLOG")"
TASK_ID="$(printf '%s\n' "$NEXT_JSON" | json_get id)"

[[ -n "$TASK_ID" ]] || {
  echo "no next task found" >&2
  exit 1
}

SEMANTIC_BEFORE="$("$PYTHON_BIN" "$REPO_ROOT/backlog_manager.py" semantic-snapshot "$BACKLOG")"
FAIL_BEFORE="$(task_fail_count "$BACKLOG" "$TASK_ID")"
HEAD_BEFORE="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

set +e
FIRST_OUTPUT="$("$REPO_ROOT/loop.sh" 1 "$PROJECT_DIR" 2>&1)"
FIRST_STATUS=$?
set -e

if [[ "$FIRST_STATUS" -eq 0 ]]; then
  echo "expected split task run to stop without PASS" >&2
  exit 1
fi

if grep -F -- "- [!\\] $TASK_ID:" "$BACKLOG" >/dev/null; then
  echo "malformed blocked marker was written" >&2
  exit 1
fi
if printf '%s\n' "$FIRST_OUTPUT" | grep -F -- '[!\]' >/dev/null; then
  echo "malformed blocked marker appeared in first output" >&2
  exit 1
fi

if ! grep -F -- "- [!] $TASK_ID:" "$BACKLOG" >/dev/null; then
  echo "task was not marked blocked with [!]" >&2
  exit 1
fi

FAIL_AFTER="$(task_fail_count "$BACKLOG" "$TASK_ID")"
if [[ "$FAIL_AFTER" != "$FAIL_BEFORE" ]]; then
  echo "fail count changed: before=$FAIL_BEFORE after=$FAIL_AFTER" >&2
  exit 1
fi

SEMANTIC_AFTER="$("$PYTHON_BIN" "$REPO_ROOT/backlog_manager.py" semantic-snapshot "$BACKLOG")"
if [[ "$SEMANTIC_AFTER" != "$SEMANTIC_BEFORE" ]]; then
  echo "semantic backlog fields changed" >&2
  exit 1
fi

PROGRESS_FILE="$PROJECT_DIR/.loop-agent/progress.txt"
PROGRESS_WINDOW="$PROJECT_DIR/.loop-agent/progress_window.md"
REPORT_FILE="$PROJECT_DIR/.loop-agent/report.md"
EVENTS_FILE="$PROJECT_DIR/.loop-agent/events.jsonl"
assert_file_contains "$PROGRESS_FILE" "=== Loop 1: Split Task Proposal ==="
assert_file_contains "$PROGRESS_FILE" "Original task: $TASK_ID -"
assert_file_contains "$PROGRESS_FILE" "Blocked reason: Split task proposal requires review before more implementation."
assert_file_contains "$PROGRESS_FILE" "Current Files:"
assert_file_contains "$PROGRESS_FILE" "Current Depends:"
assert_file_contains "$PROGRESS_FILE" "Current Verify:"
assert_file_contains "$PROGRESS_FILE" "Current Completion criteria:"
assert_file_contains "$PROGRESS_FILE" "Suggested child task count:"
assert_file_contains "$PROGRESS_FILE" "Suggested child task 1:"
assert_file_contains "$PROGRESS_FILE" "Child 1 Files:"
assert_file_contains "$PROGRESS_FILE" "Child 1 Depends:"
assert_file_contains "$PROGRESS_FILE" "Child 1 Verify:"
assert_file_contains "$PROGRESS_FILE" "Child 1 Completion criteria:"
assert_file_contains "$PROGRESS_FILE" "Fail count unchanged: $FAIL_BEFORE"
assert_file_contains "$PROGRESS_FILE" "Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria"
assert_file_contains "$PROGRESS_FILE" "Recommended action: Review the split proposal and manually replace the blocked task with child tasks if appropriate."
assert_file_contains "$PROGRESS_FILE" "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."

assert_file_contains "$PROGRESS_WINDOW" "Split Task Proposal"
assert_file_contains "$PROGRESS_WINDOW" "Original task: $TASK_ID -"
assert_file_contains "$PROGRESS_WINDOW" "Current Files:"
assert_file_contains "$PROGRESS_WINDOW" "Current Depends:"
assert_file_contains "$PROGRESS_WINDOW" "Current Verify:"
assert_file_contains "$PROGRESS_WINDOW" "Current Completion criteria:"
assert_file_contains "$PROGRESS_WINDOW" "Suggested child task count:"
assert_file_contains "$PROGRESS_WINDOW" "Suggested child task 1:"
assert_file_contains "$PROGRESS_WINDOW" "Child 1 Files:"
assert_file_contains "$PROGRESS_WINDOW" "Child 1 Depends:"
assert_file_contains "$PROGRESS_WINDOW" "Child 1 Verify:"
assert_file_contains "$PROGRESS_WINDOW" "Child 1 Completion criteria:"
assert_file_contains "$PROGRESS_WINDOW" "Fail count unchanged: $FAIL_BEFORE"
assert_file_contains "$PROGRESS_WINDOW" "Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria"
assert_file_contains "$PROGRESS_WINDOW" "Recommended action: Review the split proposal and manually replace the blocked task with child tasks if appropriate."

assert_file_contains "$REPORT_FILE" "BLOCKED: SPLIT_TASK"
assert_file_contains "$REPORT_FILE" "suggested child task count:"
assert_split_task_block_event "$EVENTS_FILE" "$TASK_ID"

assert_no_task_children "$BACKLOG" "$TASK_ID"

HEAD_AFTER="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
if [[ "$HEAD_AFTER" != "$HEAD_BEFORE" ]]; then
  echo "HEAD changed: before=$HEAD_BEFORE after=$HEAD_AFTER" >&2
  exit 1
fi

if printf '%s\n' "$FIRST_OUTPUT" | grep -q "PASS commit:"; then
  if ! printf '%s\n' "$FIRST_OUTPUT" | grep -q "PASS commit: skipped"; then
    echo "unexpected PASS commit output" >&2
    exit 1
  fi
fi

set +e
SECOND_OUTPUT="$("$REPO_ROOT/loop.sh" 1 "$PROJECT_DIR" 2>&1)"
set -e

if printf '%s\n' "$SECOND_OUTPUT" | grep -F "Current task: $TASK_ID" >/dev/null; then
  echo "blocked split task was retried" >&2
  exit 1
fi

if ! grep -F -- "- [!] $TASK_ID:" "$BACKLOG" >/dev/null; then
  echo "blocked marker did not persist" >&2
  exit 1
fi

if grep -F -- "- [!\\] $TASK_ID:" "$BACKLOG" >/dev/null; then
  echo "malformed blocked marker was written on second run" >&2
  exit 1
fi
if printf '%s\n' "$SECOND_OUTPUT" | grep -F -- '[!\]' >/dev/null; then
  echo "malformed blocked marker appeared in second output" >&2
  exit 1
fi

FAIL_AFTER_SECOND="$(task_fail_count "$BACKLOG" "$TASK_ID")"
if [[ "$FAIL_AFTER_SECOND" != "$FAIL_BEFORE" ]]; then
  echo "fail count changed after second run: before=$FAIL_BEFORE after=$FAIL_AFTER_SECOND" >&2
  exit 1
fi
