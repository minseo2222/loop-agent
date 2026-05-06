#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

die() {
  echo "$*" >&2
  if [[ -f "$TMP_DIR/loop.out" ]]; then
    echo "--- loop.out ---" >&2
    cat "$TMP_DIR/loop.out" >&2
  fi
  if [[ -f "$TMP_DIR/loop.err" ]]; then
    echo "--- loop.err ---" >&2
    cat "$TMP_DIR/loop.err" >&2
  fi
  if [[ -f "$PROJECT/.loop-agent/plan_critique.md" ]]; then
    echo "--- plan_critique.md ---" >&2
    cat "$PROJECT/.loop-agent/plan_critique.md" >&2
  fi
  if [[ -f "$PROJECT/.loop-agent/backlog.md" ]]; then
    echo "--- backlog.md ---" >&2
    cat "$PROJECT/.loop-agent/backlog.md" >&2
  fi
  if [[ -f "$PROJECT/.loop-agent/progress.txt" ]]; then
    echo "--- progress.txt ---" >&2
    cat "$PROJECT/.loop-agent/progress.txt" >&2
  fi
  exit 1
}

PROJECT="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
COUNT_FILE="$TMP_DIR/gemini-count"
mkdir -p "$PROJECT/.loop-agent" "$FAKE_BIN"

cat > "$FAKE_BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
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
# Plan - Loop 1

## Goal
Drive SPLIT_TASK proposal-only behavior.

## Tasks

### Task 1: Split candidate
- File: app.txt
- What to do: Make a change that is too broad for one task.
- Completion criteria:
  - [ ] Existing behavior remains.
  - [ ] verify: `echo verify`
OUT
    ;;
  2)
    cat <<'OUT'
# Plan Review - Loop 1

## Notes
none

VERDICT: PASS
OUT
    ;;
  3)
    cat <<'OUT'
# Implementation Summary - Loop 1

## Files read
- plan.md
- plan_critique.md
- app.txt

## Tasks completed
- [ ] Task 1: Split candidate - NOT DONE: split required.

## Files changed
None.

## Completion criteria status
Task 1:
- [ ] Existing behavior remains.
- [ ] verify: `echo verify`

## Additional files needed
none

## Unrelated issues noticed (not fixed)
none
OUT
    ;;
  4)
    cat <<'OUT'
# Implementation Review - Loop 1

## Files read
- plan.md
- impl_summary.md

## Completion criteria check

### Task 1: Split candidate
- [ ] Existing behavior remains: split required.

## Code quality issues
none

## Out-of-scope changes
none

## Scope expansion needed
Split this task into these child tasks:
- Child task: isolate data model changes.
- Child task: add behavior coverage.

## Notes
none

## Next Planner guidance
Review the split proposal.

VERDICT: SPLIT_TASK
OUT
    ;;
  *)
    echo "unexpected gemini call $count" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKE_BIN/gemini"

cat > "$PROJECT/.loop-agent/backlog.md" <<'BACKLOG'
# Project Backlog

- [ ] Task 1.1: Split candidate
  - Files: app.txt
  - Depends: none
  - Verify: echo verify
  - Completion criteria:
    - [ ] Existing behavior remains
  - Fail count: 0
BACKLOG

printf 'initial\n' > "$PROJECT/app.txt"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -q -m "initial"

set +e
PATH="$FAKE_BIN:$PATH" FAKE_GEMINI_COUNT="$COUNT_FILE" bash "$SCRIPT_DIR/loop.sh" run --iterations 1 --project "$PROJECT" --cli gemini > "$TMP_DIR/loop.out" 2> "$TMP_DIR/loop.err"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  die "expected run to stop without PASS"
fi

if [[ ! -d "$PROJECT/.loop-agent/proposals" ]]; then
  die "missing proposals directory"
fi

proposal_count="$(find "$PROJECT/.loop-agent/proposals" -type f -name '*split*.md' | wc -l | tr -d ' ')"
if [[ "$proposal_count" != "1" ]]; then
  die "expected exactly one split proposal, found $proposal_count"
fi

proposal_file="$(find "$PROJECT/.loop-agent/proposals" -type f -name '*split*.md' | head -n 1)"
grep -Fq "Verdict: SPLIT_TASK" "$proposal_file"
grep -Fq "Child task: isolate data model changes." "$proposal_file"
grep -Fq "Child task: add behavior coverage." "$proposal_file"

task_count="$(grep -Ec '^- \[[^]]+\] Task ' "$PROJECT/.loop-agent/backlog.md")"
if [[ "$task_count" != "1" ]]; then
  die "backlog task list changed"
fi

grep -Fq "Task 1.1: Split candidate" "$PROJECT/.loop-agent/backlog.md"
grep -Fq "Files: app.txt" "$PROJECT/.loop-agent/backlog.md"
grep -Fq "Depends: none" "$PROJECT/.loop-agent/backlog.md"
grep -Fq "Verify: echo verify" "$PROJECT/.loop-agent/backlog.md"
if grep -Fq "Task 1.2:" "$PROJECT/.loop-agent/backlog.md"; then
  die "child task was added automatically"
fi
if grep -Fq "Depends: Task" "$PROJECT/.loop-agent/backlog.md"; then
  die "dependency was edited automatically"
fi

grep -Fq "Blocked reason: Split proposal requires review before more implementation." "$PROJECT/.loop-agent/progress.txt"
grep -Fq "Backlog block result: BLOCKED" "$PROJECT/.loop-agent/progress.txt"
grep -Fq "Proposal: $proposal_file" "$PROJECT/.loop-agent/progress.txt"
