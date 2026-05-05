#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
COUNT_FILE="$TMP_DIR/codex_count"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$PROJECT_DIR/.loop-agent/evidence/loop-99" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"
printf '0\n' > "$COUNT_FILE"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "exec" ]]; then
  echo "fake codex"
  exit 0
fi

cat >/dev/null
count="$(cat "$FAKE_CODEX_COUNT" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Finish the continuation task.

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
    printf 'continued\n' >> next.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 8.7: continuation - updated next.txt
OUT
    ;;
  4)
    cat <<'OUT'
# Implementation Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
  *)
    cat <<'OUT'
VERDICT: PASS
OUT
    ;;
esac
SH
chmod +x "$FAKE_BIN/codex"

cd "$PROJECT_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
printf 'baseline\n' > app.txt
printf 'base\n' > next.txt
git add app.txt next.txt
git commit -q -m "initial"
SNAPSHOT="$(git rev-parse HEAD)"

cat > .loop-agent/backlog.md <<'MD'
# Backlog

## Tasks

- [ ] Task 8.6: Crash recovery source task
  - Depends: none
  - Files:
    - `app.txt`
  - Completion criteria:
    - [ ] Recovery is recorded.
    - [ ] verify: `true`
  - Fail count: 4

- [ ] Task 8.7: Continuation task
  - Depends: none
  - Files:
    - `next.txt`
  - Completion criteria:
    - [ ] Continuation runs.
    - [ ] verify: `true`
  - Fail count: 0
MD

cat > .loop-agent/current_transaction.json <<JSON
{
  "loop": 99,
  "task_id": "Task 8.6",
  "task_name": "Crash recovery source task",
  "stage": "implementer",
  "snapshot_commit": "$SNAPSHOT",
  "evidence_dir": "$PROJECT_DIR/.loop-agent/evidence/loop-99",
  "evidence_rel": ".loop-agent/evidence/loop-99/",
  "complete": false
}
JSON

printf '# Loop Agent Progress\n---\n' > .loop-agent/progress.txt
printf 'evidence survives\n' > .loop-agent/evidence/loop-99/marker.txt
printf 'dirty change\n' > app.txt
printf 'untracked\n' > dirty.tmp

PATH="$FAKE_BIN:$PATH" \
HOME="$FAKE_HOME" \
FAKE_CODEX_COUNT="$COUNT_FILE" \
COMMIT_ON_PASS=1 \
LOOP_MAX_ATTEMPTS=5 \
bash "$ROOT_DIR/loop.sh" run --project "$PROJECT_DIR" --iterations 1 --cli codex >/tmp/loop-agent-crash-recovery.out 2>&1 || {
  cat /tmp/loop-agent-crash-recovery.out >&2
  cat .loop-agent/progress.txt >&2 || true
  cat .loop-agent/backlog.md >&2 || true
  fail "loop.sh run failed"
}

[[ "$(cat app.txt)" == "baseline" ]] || fail "tracked dirty change was not rolled back"
[[ ! -e dirty.tmp ]] || fail "untracked dirty change was not removed"
[[ -f .loop-agent/evidence/loop-99/marker.txt ]] || fail "evidence was not preserved"
grep -q "Startup Recovery" .loop-agent/progress.txt || fail "progress log missing startup recovery"
grep -q "Task completion: skipped" .loop-agent/progress.txt || fail "progress log does not say completion was skipped"
grep -q "Startup Recovery" .loop-agent/progress_window.md || fail "progress window missing recovery summary"
grep -q '"complete": true' .loop-agent/current_transaction.json || fail "transaction was not completed after recovery"
grep -q 'Fail count: 5' .loop-agent/backlog.md || fail "recovered task fail count was not updated"
grep -q 'Task 8.7' .loop-agent/current_task.md || fail "run did not continue to the next safe task"
grep -q 'continued' next.txt || fail "continuation task did not run"
! grep -q '^- \[x\] Task 8.6:' .loop-agent/backlog.md || fail "recovered task was marked complete"
[[ "$(cat "$COUNT_FILE")" -ge 4 ]] || fail "fake codex was not invoked for continuation"

echo "PASS"
