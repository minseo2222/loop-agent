#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
LOG_FILE="$TMP_DIR/fake_codex.log"

mkdir -p "$PROJECT_DIR/.loop-agent" "$BIN_DIR" "$HOME_DIR/.codex"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

## Tasks

- [ ] Task 1.1: Evidence prompt test
  - Files: allowed.txt
  - Completion criteria:
    - verify: true
  - Depends: none
  - Fail count: 0
BACKLOG

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" config core.autocrlf false
printf 'initial\n' > "$PROJECT_DIR/allowed.txt"
git -C "$PROJECT_DIR" add allowed.txt .loop-agent/backlog.md
git -C "$PROJECT_DIR" commit -q -m "initial"

cat > "$BIN_DIR/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
printf '%s\n---PROMPT---\n' "$prompt" >> "$FAKE_CODEX_LOG"

if grep -q '# Impl Critic' <<< "$prompt"; then
  cat <<'REVIEW'
# Implementation Review

## Files read
- plan.md
- impl_summary.md

## Completion criteria check
none

## Code quality issues
none

## Out-of-scope changes
none

## Scope expansion needed
none

## Notes
none

## Next Planner guidance
none needed

VERDICT: PASS
REVIEW
elif grep -q '# Plan Critic' <<< "$prompt"; then
  cat <<'CRITIQUE'
# Plan Review

## Notes
none

VERDICT: PASS
CRITIQUE
elif grep -q '# Implementer' <<< "$prompt"; then
  printf 'changed\n' > allowed.txt
  printf 'out of scope\n' > extra.txt
  cat <<'SUMMARY'
# Implementation Summary

## Files read
- plan.md
- plan_critique.md
- allowed.txt

## Tasks completed
- [x] Task 1: Evidence prompt test - changed allowed file

## Files changed
| File | Action | What changed |
|------|--------|--------------|
| allowed.txt | modified | changed content |

## Completion criteria status
Task 1:
- [x] verify: `true` - expected to pass

## Additional files needed
none

## Unrelated issues noticed (not fixed)
none
SUMMARY
else
  cat <<'PLAN'
# Plan

## Goal
Exercise shell evidence.

## Tasks

### Task 1: Evidence prompt test
- File: allowed.txt
- What to do: Change allowed file.
- Completion criteria:
  - [ ] verify: `true`
PLAN
fi
FAKE_CODEX
chmod +x "$BIN_DIR/codex"

set +e
PATH="$BIN_DIR:$PATH" HOME="$HOME_DIR" FAKE_CODEX_LOG="$LOG_FILE" \
  bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex \
  > "$TMP_DIR/loop.out" 2> "$TMP_DIR/loop.err"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Expected loop to fail on out-of-scope evidence scenario." >&2
  exit 1
fi

PROMPT_FILE="$PROJECT_DIR/.loop-agent/impl_critic_rendered.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Missing rendered Impl Critic prompt." >&2
  cat "$TMP_DIR/loop.out" >&2
  cat "$TMP_DIR/loop.err" >&2
  exit 1
fi

grep -q 'Evidence directory: .loop-agent/evidence/loop-1/' "$PROMPT_FILE"
grep -q 'changed_files.txt' "$PROMPT_FILE"
grep -q 'diff_stat.txt' "$PROMPT_FILE"
grep -q 'out_of_scope.txt' "$PROMPT_FILE"
grep -q 'extra.txt' "$PROMPT_FILE"
grep -q 'Evidence directory: .loop-agent/evidence/loop-1/' "$LOG_FILE"
