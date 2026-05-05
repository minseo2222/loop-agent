#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_STATE="$TMP_DIR/gemini-count"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "expected '$text' in $file"
}

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN"
printf 'initial\n' > "$PROJECT_DIR/app.txt"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [ ] Task 1.1: Proposal format fixture
  - Size: S
  - Files:
    - app.txt
  - Description: Exercise proposal-only verdict handling.
  - Completion criteria:
    - verify: `true`
  - Depends: none
  - Fail count: 0
BACKLOG

cat > "$FAKE_BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
  echo "fake gemini"
  exit 0
fi

count=0
if [[ -f "$FAKE_GEMINI_STATE" ]]; then
  count="$(cat "$FAKE_GEMINI_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_GEMINI_STATE"

phase=$(( (count - 1) % 4 + 1 ))
loop=$(( (count - 1) / 4 + 1 ))

case "$phase" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise proposal generation.

## Tasks

### Task 1: Proposal fixture
- File: app.txt
- What to do: Exercise proposal generation.
- Completion criteria:
  - [ ] verify: `true`
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
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [ ] Task 1: Proposal fixture - NOT DONE: proposal verdict fixture
OUT
    ;;
  4)
    if [[ "$loop" -eq 1 ]]; then
      cat <<'OUT'
# Implementation Critique

## Scope expansion needed
- `extra.txt` - needed to complete the fixture

VERDICT: SCOPE_EXPAND
OUT
    else
      cat <<'OUT'
# Implementation Critique

## Split task
- Child task A: isolate proposal format writer.
- Child task B: convert proposal branches.

VERDICT: SPLIT_TASK
OUT
    fi
    ;;
esac
FAKE
chmod +x "$FAKE_BIN/gemini"

export PATH="$FAKE_BIN:$PATH"
export FAKE_GEMINI_STATE="$FAKE_STATE"
export GEMINI_API_KEY="fake"
export GIT_AUTHOR_NAME="loop-agent test"
export GIT_AUTHOR_EMAIL="loop-agent-test@example.com"
export GIT_COMMITTER_NAME="loop-agent test"
export GIT_COMMITTER_EMAIL="loop-agent-test@example.com"

set +e
bash "$REPO_DIR/loop.sh" run --iterations 2 --project "$PROJECT_DIR" --cli gemini > "$TMP_DIR/run.log" 2>&1
status=$?
set -e

[[ "$status" -ne 0 ]] || fail "expected proposal-only run to finish without PASS"

PROPOSALS_DIR="$PROJECT_DIR/.loop-agent/proposals"
scope_proposal="$(find "$PROPOSALS_DIR" -name 'scope_expand_loop_*.md' -print | head -1)"
split_proposal="$(find "$PROPOSALS_DIR" -name 'split_task_loop_*.md' -print | head -1)"

[[ -n "$scope_proposal" ]] || fail "scope expansion proposal was not generated"
[[ -n "$split_proposal" ]] || fail "split task proposal was not generated"

for proposal in "$scope_proposal" "$split_proposal"; do
  assert_contains "$proposal" "Task ID: Task 1.1"
  assert_contains "$proposal" "Verdict:"
  assert_contains "$proposal" "Requested Change:"
  assert_contains "$proposal" "Reason:"
  assert_contains "$proposal" "Evidence Path:"
  assert_contains "$proposal" "No backlog semantic change was applied."
done

assert_contains "$scope_proposal" "Verdict: SCOPE_EXPAND"
assert_contains "$scope_proposal" '## Requested files'
assert_contains "$scope_proposal" '`extra.txt`'
assert_contains "$scope_proposal" "No backlog Files change was applied."

assert_contains "$split_proposal" "Verdict: SPLIT_TASK"
assert_contains "$split_proposal" "## Suggested child tasks"
assert_contains "$split_proposal" "Child task A"
assert_contains "$split_proposal" "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."

assert_contains "$PROJECT_DIR/.loop-agent/progress.txt" "Scope Expand Proposal"
assert_contains "$PROJECT_DIR/.loop-agent/progress.txt" "Split Task Proposal"
assert_contains "$PROJECT_DIR/.loop-agent/progress.txt" "Blocked reason: Split proposal requires review before more implementation."

if grep -Fq "extra.txt" "$PROJECT_DIR/.loop-agent/backlog.md"; then
  fail "scope expansion proposal mutated backlog Files"
fi
