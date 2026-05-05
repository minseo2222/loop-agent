#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
COUNT_FILE="$TMP_DIR/codex_count"
RUN_LOG="$TMP_DIR/loop.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"
printf '0\n' > "$COUNT_FILE"

cat > "$FAKE_BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(mktemp)"
cat > "$prompt"

count="$(cat "$TEST_FAKE_CODEX_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_FAKE_CODEX_COUNT"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise rollback preservation.

## Tasks

### Task 1: Rollback preservation
- File: `preexisting.txt`
- File: `task-created.txt`
- What to do: Create one untracked file and then fail review.
- Completion criteria:
  - [ ] verify: `true`

VERDICT: PASS
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
    printf 'created during implementation\n' > task-created.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Rollback preservation - created task-created.txt

## Completion criteria status
Task 1:
- [x] verify: `true`
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critique

## Notes
forced failure

VERDICT: FAIL
OUT
    ;;
  *)
    echo "unexpected fake codex call: $count" >&2
    exit 1
    ;;
esac

rm -f "$prompt"
FAKE
chmod +x "$FAKE_BIN/codex"

cd "$PROJECT_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

cat > .loop-agent/backlog.md <<'BACKLOG'
# Backlog

## Tasks

- [ ] Task 1: Rollback preservation
  - Depends: none
  - Files:
    - preexisting.txt
    - task-created.txt
  - Completion criteria:
    - [ ] Pre-existing untracked file remains after rollback.
    - [ ] Task-created untracked file is removed by rollback.
    - [ ] Evidence remains under `.loop-agent/evidence/loop-1/`.
    - [ ] verify: `true`
  - Fail count: 0
BACKLOG

cat > tracked.txt <<'TRACKED'
tracked baseline
TRACKED
cat > .gitignore <<'IGNORE'
.loop-agent/
IGNORE
git add tracked.txt .gitignore
git add -f .loop-agent/backlog.md
git commit -q -m "baseline"

cat > preexisting.txt <<'PRE'
pre-existing untracked content
PRE

set +e
LOOP_ALLOW_DIRTY=1 \
TEST_FAKE_CODEX_COUNT="$COUNT_FILE" \
HOME="$FAKE_HOME" \
PATH="$FAKE_BIN:$PATH" \
bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex > "$RUN_LOG" 2>&1
run_status=$?
set -e

if [[ "$run_status" -eq 0 ]]; then
  echo "Expected loop.sh to exit non-zero after forced Impl Critic FAIL." >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

if [[ ! -f preexisting.txt ]]; then
  echo "Pre-existing untracked file was removed." >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

if [[ "$(cat preexisting.txt)" != "pre-existing untracked content" ]]; then
  echo "Pre-existing untracked file content changed." >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

if [[ -e task-created.txt ]]; then
  echo "Task-created untracked file survived rollback." >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

if [[ ! -d .loop-agent/evidence/loop-1 ]]; then
  echo "Evidence directory was not preserved." >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

if [[ ! -f .loop-agent/evidence/loop-1/impl_fail_reason.md ]]; then
  echo "Impl failure evidence was not preserved." >&2
  if [[ -f .loop-agent/evidence/loop-1/scope_check.txt ]]; then
    cat .loop-agent/evidence/loop-1/scope_check.txt >&2
  fi
  if [[ -f .loop-agent/evidence/loop-1/allowed_files.txt ]]; then
    cat .loop-agent/evidence/loop-1/allowed_files.txt >&2
  fi
  if [[ -f .loop-agent/evidence/loop-1/changed_files.txt ]]; then
    cat .loop-agent/evidence/loop-1/changed_files.txt >&2
  fi
  cat "$RUN_LOG" >&2
  exit 1
fi

status_line="$(git status --porcelain -- preexisting.txt)"
if [[ "$status_line" != "?? preexisting.txt" ]]; then
  echo "Pre-existing file is not still untracked: $status_line" >&2
  cat "$RUN_LOG" >&2
  exit 1
fi

echo "PASS"
