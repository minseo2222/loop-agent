#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
FAKE_STATE="$TMP_DIR/codex_count"
RUN_LOG="$TMP_DIR/run.log"

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
printf 'base\n' > "$PROJECT_DIR/allowed.txt"
git -C "$PROJECT_DIR" add allowed.txt
git -C "$PROJECT_DIR" commit -q -m "initial"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [ ] Task 1.1: Scope gate fixture
  - Files:
    - allowed.txt
  - Depends: none
  - Completion criteria:
    - [ ] Update the allowed file only.
    - [ ] verify: `test -f allowed.txt`
  - Fail count: 0
BACKLOG

cat > "$FAKE_BIN/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null

count=0
if [[ -f "$FAKE_CODEX_STATE" ]]; then
  count="$(cat "$FAKE_CODEX_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_STATE"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Trigger an out-of-scope change.

## Tasks

### Task 1: Scope gate fixture
- File: `allowed.txt`
- What to do: Update the allowed file only.
- Completion criteria:
  - [ ] verify: `test -f allowed.txt`
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
    printf 'implemented\n' > allowed.txt
    printf 'out of scope\n' > forbidden.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Scope gate fixture - updated allowed file and leaked another file.

## Completion criteria status
- [x] verify: `test -f allowed.txt`
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critique

## Notes
critic says pass

VERDICT: PASS
OUT
    ;;
  *)
    printf 'VERDICT: PASS\n'
    ;;
esac
FAKE_CODEX
chmod +x "$FAKE_BIN/codex"

before_count="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"

set +e
PATH="$FAKE_BIN:$PATH" \
HOME="$FAKE_HOME" \
FAKE_CODEX_STATE="$FAKE_STATE" \
CODEX_MODEL="fake-model" \
bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" > "$RUN_LOG" 2>&1
run_status=$?
set -e

if [[ "$run_status" -eq 0 ]]; then
  echo "expected loop to exit non-zero when scope check prevents PASS"
  cat "$RUN_LOG"
  exit 1
fi

if git -C "$PROJECT_DIR" log --format=%s | grep -q '^loop-agent: PASS'; then
  echo "unexpected PASS commit was created"
  git -C "$PROJECT_DIR" log --oneline
  cat "$RUN_LOG"
  exit 1
fi

after_count="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
expected_count=$((before_count + 1))
if [[ "$after_count" -ne "$expected_count" ]]; then
  echo "expected only the pre-implementer snapshot commit"
  echo "before=$before_count after=$after_count expected=$expected_count"
  git -C "$PROJECT_DIR" log --oneline
  cat "$RUN_LOG"
  exit 1
fi

if [[ -e "$PROJECT_DIR/forbidden.txt" ]]; then
  echo "out-of-scope file was not rolled back"
  cat "$RUN_LOG"
  exit 1
fi

if [[ "$(cat "$PROJECT_DIR/allowed.txt")" != "base" ]]; then
  echo "allowed implementation change was not rolled back"
  cat "$RUN_LOG"
  exit 1
fi

if ! grep -Eq 'Fail count:[[:space:]]*1|BLOCKED' "$PROJECT_DIR/.loop-agent/backlog.md"; then
  echo "fail count was not incremented or blocked"
  cat "$PROJECT_DIR/.loop-agent/backlog.md"
  cat "$RUN_LOG"
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/.loop-agent/evidence/loop-1/out_of_scope.txt" ]]; then
  echo "out-of-scope evidence was not preserved"
  cat "$RUN_LOG"
  exit 1
fi

if ! grep -qx 'forbidden.txt' "$PROJECT_DIR/.loop-agent/evidence/loop-1/out_of_scope.txt"; then
  echo "out-of-scope evidence did not identify forbidden.txt"
  cat "$PROJECT_DIR/.loop-agent/evidence/loop-1/out_of_scope.txt"
  cat "$RUN_LOG"
  exit 1
fi

if ! grep -q 'Final decision: FAIL' "$PROJECT_DIR/.loop-agent/progress.txt"; then
  echo "progress did not record the non-PASS scope decision"
  cat "$PROJECT_DIR/.loop-agent/progress.txt"
  cat "$RUN_LOG"
  exit 1
fi

if ! grep -q 'PASS commit: skipped' "$PROJECT_DIR/.loop-agent/progress.txt"; then
  echo "progress did not record skipped PASS commit handling"
  cat "$PROJECT_DIR/.loop-agent/progress.txt"
  cat "$RUN_LOG"
  exit 1
fi

