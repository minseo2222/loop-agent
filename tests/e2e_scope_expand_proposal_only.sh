#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
mkdir -p "$PROJECT_DIR/.loop-agent" "$PROJECT_DIR/src" "$FAKE_BIN" "$FAKE_HOME/.codex"

printf '{}\n' > "$FAKE_HOME/.codex/auth.json"
printf 'existing file\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

## Tasks

- [ ] Task 1: Proposal-only scope expansion
  - Files:
    - README.md
  - Depends: none
  - Completion criteria:
    - [ ] verify: `true`
  - Fail count: 0
BACKLOG

FAKE_CODEX_COUNT="$TMP_DIR/codex_count"
printf '0\n' > "$FAKE_CODEX_COUNT"

cat > "$FAKE_BIN/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null
count="$(cat "$FAKE_CODEX_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Trigger a scope expansion request.

## Tasks

### Task 1: Proposal-only scope expansion
- File: README.md
- What to do: Leave this task incomplete so the fake critic requests scope expansion.
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

## Files read
- plan.md
- plan_critique.md
- README.md

## Tasks completed
- [ ] Task 1: Proposal-only scope expansion - NOT DONE: src/extra.txt is outside the task scope.

## Files changed
None.

## Completion criteria status
Task 1:
- [ ] verify: `true`

## Additional files needed
src/extra.txt - needed to complete the task.

## Unrelated issues noticed (not fixed)
none
OUT
    ;;
  4)
    cat <<'OUT'
# Implementation Review

## Completion criteria check

### Task 1: Proposal-only scope expansion
- [ ] verify: `true`: scope needs expansion first.

## Code quality issues
none

## Out-of-scope changes
none

## Scope expansion needed
- `src/extra.txt` - needed to complete the task.

## Notes
none

## Next Planner guidance
Expand Task scope to include listed files, then retry

VERDICT: SCOPE_EXPAND
OUT
    ;;
  *)
    echo "unexpected codex invocation: $count" >&2
    exit 1
    ;;
esac
FAKE_CODEX
chmod +x "$FAKE_BIN/codex"

set +e
HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" FAKE_CODEX_COUNT="$FAKE_CODEX_COUNT" \
  bash "$ROOT_DIR/loop.sh" run --project "$PROJECT_DIR" --iterations 1 --cli codex \
  > "$TMP_DIR/loop.out" 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "expected loop run to fail or block after SCOPE_EXPAND, but it exited 0" >&2
  cat "$TMP_DIR/loop.out" >&2
  exit 1
fi

if [[ -d "$PROJECT_DIR/.loop-agent/proposals" ]]; then
  proposal_count="$(find "$PROJECT_DIR/.loop-agent/proposals" -type f | wc -l | tr -d ' ')"
else
  proposal_count=0
fi
if [[ "$proposal_count" != "1" ]]; then
  echo "expected exactly one scope expansion proposal, found $proposal_count" >&2
  cat "$TMP_DIR/loop.out" >&2
  exit 1
fi

proposal_file="$(find "$PROJECT_DIR/.loop-agent/proposals" -type f | head -1)"
grep -q 'src/extra.txt' "$proposal_file"
grep -q 'needed to complete the task' "$proposal_file"
grep -q 'No backlog Files change was applied' "$proposal_file"

if grep -q 'src/extra.txt' "$PROJECT_DIR/.loop-agent/backlog.md"; then
  echo "backlog Files field gained requested file unexpectedly" >&2
  cat "$PROJECT_DIR/.loop-agent/backlog.md" >&2
  exit 1
fi

grep -q 'Fail count: 1' "$PROJECT_DIR/.loop-agent/backlog.md"
grep -q 'Scope Expand Proposal' "$PROJECT_DIR/.loop-agent/progress.txt"
