#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$TMP_DIR/run.out" ]]; then
    echo "--- run.out ---" >&2
    cat "$TMP_DIR/run.out" >&2
  fi
  if [[ -f "$TMP_DIR/run.err" ]]; then
    echo "--- run.err ---" >&2
    cat "$TMP_DIR/run.err" >&2
  fi
  if [[ -n "${PROJECT:-}" && -d "${PROJECT:-}/.git" ]]; then
    echo "--- git log ---" >&2
    git -C "$PROJECT" log --oneline --name-status -3 >&2 || true
  fi
  exit 1
}

PYTHON_BIN=""
for candidate in python3 python; do
  candidate_path="$(command -v "$candidate" 2>/dev/null || true)"
  if [[ -n "$candidate_path" && "$candidate_path" != *WindowsApps* ]]; then
    PYTHON_BIN="$candidate_path"
    break
  fi
done
[[ -n "$PYTHON_BIN" ]] || fail "python is required"

PROJECT="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
mkdir -p "$PROJECT/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$PROJECT/app.txt" <<'EOF_APP'
original
EOF_APP

cat > "$PROJECT/.gitignore" <<'EOF_GITIGNORE'
.loop-agent/
EOF_GITIGNORE

cat > "$PROJECT/.loop-agent/backlog.md" <<'EOF_BACKLOG'
# Backlog

## Phase 1

- [ ] Task 1.1: Fail handler fixture
  - Description: Keep fixture semantics.
  - Files: `app.txt`
  - Depends: none
  - Fail count: 0
  - Verify:
    - [ ] verify: `test -f app.txt`
  - Completion criteria:
    - [ ] app remains under test
EOF_BACKLOG

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" config core.autocrlf false
git -C "$PROJECT" add app.txt .gitignore
git -C "$PROJECT" add -f .loop-agent/backlog.md
git -C "$PROJECT" commit -q -m "initial"

SEMANTIC_BEFORE="$("$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$PROJECT/.loop-agent/backlog.md")"
COMMIT_COUNT_BEFORE="$(git -C "$PROJECT" rev-list --count HEAD)"

cat > "$FAKE_BIN/codex" <<'EOF_CODEX'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
state="${FAKE_CODEX_STATE:?}"
count=0
if [[ -f "$state" ]]; then
  count="$(cat "$state")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$state"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise FAIL handler.

## Tasks

### Task 1: Modify app
- File: app.txt
- What to do: Modify app.txt.
- Completion criteria:
  - [ ] verify: `test -f app.txt`
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
    printf 'changed by fake implementer\n' > app.txt
    cat <<'OUT'
# Implementation Summary

## Files read
- plan.md
- plan_critique.md
- app.txt

## Tasks completed
- [x] Task 1: Modify app -- changed app.txt

## Files changed
| File | Action | What changed |
|------|--------|--------------|
| app.txt | modified | changed content |

## Completion criteria status
- [x] verify: `test -f app.txt`

## Additional files needed
none

## Unrelated issues noticed (not fixed)
none
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critique

## Notes
Deterministic failure reason: fake critic rejected implementation.

VERDICT: FAIL
OUT
    ;;
  *)
    echo "unexpected codex call $count" >&2
    exit 1
    ;;
esac
EOF_CODEX
chmod +x "$FAKE_BIN/codex"

set +e
HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" FAKE_CODEX_STATE="$TMP_DIR/codex_calls" \
  COMMIT_ON_PASS=1 LOOP_VERIFY_TIMEOUT=30 \
  bash "$ROOT/loop.sh" 1 "$PROJECT" codex > "$TMP_DIR/run.out" 2> "$TMP_DIR/run.err"
RUN_STATUS=$?
set -e

[[ "$RUN_STATUS" -eq 1 ]] || fail "loop.sh should exit 1 after one FAIL-only loop, got $RUN_STATUS"
cmp -s "$PROJECT/app.txt" <(printf 'original\n') || fail "project file was not rolled back"
grep -q '  - Fail count: 1' "$PROJECT/.loop-agent/backlog.md" || fail "fail count was not incremented"
grep -q 'Deterministic failure reason: fake critic rejected implementation.' "$PROJECT/.loop-agent/evidence/loop-1/impl_fail_reason.md" || fail "failure reason evidence was not recorded"
[[ -d "$PROJECT/.loop-agent/evidence/loop-1" ]] || fail "evidence directory was not preserved"
grep -q 'Failure evidence: .loop-agent/evidence/loop-1/impl_fail_reason.md' "$PROJECT/.loop-agent/progress.txt" || fail "progress did not record failure evidence path"
grep -q 'PASS commit: skipped' "$PROJECT/.loop-agent/progress.txt" || fail "progress did not record skipped PASS commit"
grep -q 'Failure evidence: .loop-agent/evidence/loop-1/impl_fail_reason.md' "$PROJECT/.loop-agent/report.md" || fail "report did not record failure evidence path"

COMMIT_COUNT_AFTER="$(git -C "$PROJECT" rev-list --count HEAD)"
[[ "$COMMIT_COUNT_AFTER" == "$COMMIT_COUNT_BEFORE" ]] || fail "FAIL created a commit"
! grep -q '^- \[x\] Task 1.1:' "$PROJECT/.loop-agent/backlog.md" || fail "FAIL marked task complete"

SEMANTIC_AFTER="$("$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$PROJECT/.loop-agent/backlog.md")"
[[ "$SEMANTIC_AFTER" == "$SEMANTIC_BEFORE" ]] || fail "FAIL modified backlog semantic fields"

BLOCK_BACKLOG="$TMP_DIR/block_backlog.md"
cat > "$BLOCK_BACKLOG" <<'EOF_BLOCK'
# Backlog

## Phase 1

- [ ] Task 1.1: Fail handler fixture
  - Description: Keep fixture semantics.
  - Files: `app.txt`
  - Depends: none
  - Fail count: 4
  - Verify:
    - [ ] verify: `test -f app.txt`
  - Completion criteria:
    - [ ] app remains under test
EOF_BLOCK

BLOCK_SEMANTIC_BEFORE="$("$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$BLOCK_BACKLOG")"
BLOCK_RESULT="$("$PYTHON_BIN" "$ROOT/backlog_manager.py" fail "$BLOCK_BACKLOG" "Task 1.1")"
[[ "$BLOCK_RESULT" == "BLOCKED" ]] || fail "fail count threshold did not block"
grep -q '^- \[!\] Task 1.1:' "$BLOCK_BACKLOG" || fail "blocked task marker was not written"
grep -q '  - Fail count: 5' "$BLOCK_BACKLOG" || fail "blocked fail count was not written"
BLOCK_SEMANTIC_AFTER="$("$PYTHON_BIN" "$ROOT/backlog_manager.py" semantic-snapshot "$BLOCK_BACKLOG")"
[[ "$BLOCK_SEMANTIC_AFTER" == "$BLOCK_SEMANTIC_BEFORE" ]] || fail "blocked fail modified semantic fields"

echo "PASS"
