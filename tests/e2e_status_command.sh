#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/project"
mkdir -p "$PROJECT/.loop-agent"

cat > "$PROJECT/.loop-agent/backlog.md" <<'EOF_BACKLOG'
# Test Backlog

- [x] Task 1.1: Completed task
  - Depends: none
  - Fail count: 0

- [ ] Task 1.2: Ready task
  - Depends: Task 1.1
  - Fail count: 0

- [ ] Task 1.3: Waiting task
  - Depends: Task 1.2
  - Fail count: 0

- [!] Task 1.4: Blocked task
  - Depends: none
  - Fail count: 0
EOF_BACKLOG

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
for cmd in codex gemini envsubst; do
  cat > "$FAKE_BIN/$cmd" <<'EOF_FAKE'
#!/usr/bin/env bash
exit 97
EOF_FAKE
  chmod +x "$FAKE_BIN/$cmd"
done

snapshot_project() {
  local dir="$1"
  (
    cd "$dir"
    find . -type f -print | sort | while IFS= read -r file; do
      sha256sum "$file"
    done
  )
}

assert_contains() {
  local output="$1"
  local expected="$2"
  if ! grep -Fq "$expected" <<< "$output"; then
    echo "Missing expected output: $expected" >&2
    echo "$output" >&2
    exit 1
  fi
}

BEFORE="$(snapshot_project "$PROJECT")"
OUTPUT="$(PATH="$FAKE_BIN:$PATH" "$ROOT/loop.sh" status --project "$PROJECT")"
AFTER="$(snapshot_project "$PROJECT")"

if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "status modified project files" >&2
  exit 1
fi

assert_contains "$OUTPUT" "Total tasks: 4"
assert_contains "$OUTPUT" "Done: 1"
assert_contains "$OUTPUT" "Pending: 2"
assert_contains "$OUTPUT" "Blocked: 1"
assert_contains "$OUTPUT" "Next task: Task 1.2 - Ready task"
assert_contains "$OUTPUT" "Last decision: none"

cat > "$PROJECT/.loop-agent/events.jsonl" <<'EOF_EVENTS'
{"event":"decision","type":"decision","outcome":"FAIL","status":"FAIL","stage":"final_decision:FAIL"}
{"event":"decision","type":"decision","outcome":"PASS","status":"PASS","stage":"final_decision:PASS","task_id":"Task 1.2"}
EOF_EVENTS

BEFORE="$(snapshot_project "$PROJECT")"
OUTPUT="$(PATH="$FAKE_BIN:$PATH" "$ROOT/loop.sh" status --project "$PROJECT")"
AFTER="$(snapshot_project "$PROJECT")"

if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "status modified project files with events.jsonl present" >&2
  exit 1
fi

assert_contains "$OUTPUT" "Last decision: PASS"
assert_contains "$OUTPUT" "task_id=Task 1.2"
