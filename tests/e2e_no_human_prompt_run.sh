#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  if [[ -n "${OUTPUT_FILE:-}" && -f "$OUTPUT_FILE" ]]; then
    echo "--- loop output ---" >&2
    cat "$OUTPUT_FILE" >&2
    echo "--- end loop output ---" >&2
  fi
  exit 1
}

command -v timeout >/dev/null 2>&1 || fail "timeout is required"
command -v git >/dev/null 2>&1 || fail "git is required"

TMP_DIR="$(mktemp -d)"
STDIN_PID=""
cleanup() {
  if [[ -n "$STDIN_PID" ]]; then
    kill "$STDIN_PID" 2>/dev/null || true
    wait "$STDIN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
OUTPUT_FILE="$TMP_DIR/run.out"
EDITOR_LOG="$TMP_DIR/editor.log"
CODEX_COUNT="$TMP_DIR/codex.count"
CODEX_STDIN_LOG="$TMP_DIR/codex.stdin"
STDIN_FIFO="$TMP_DIR/stdin.fifo"

mkdir -p "$PROJECT_DIR/.loop-agent" "$BIN_DIR" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"
printf '# Temp project\n' > "$PROJECT_DIR/README.md"
cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [ ] Task 1.1: Fake task
  - Files:
    - README.md
  - Fail count: 0
BACKLOG

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "loop-test@example.com"
git -C "$PROJECT_DIR" config user.name "Loop Test"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m "initial"

cat > "$BIN_DIR/envsubst" <<'FAKE_ENVSUBST'
#!/usr/bin/env bash
cat
FAKE_ENVSUBST
chmod +x "$BIN_DIR/envsubst"

cat > "$BIN_DIR/fake-editor" <<'FAKE_EDITOR'
#!/usr/bin/env bash
set -euo pipefail
printf 'EDITOR_CALLED\n' >> "${EDITOR_LOG:?}"
exit 1
FAKE_EDITOR
chmod +x "$BIN_DIR/fake-editor"

cat > "$BIN_DIR/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [[ -f "${FAKE_CODEX_COUNT:?}" ]]; then
  count="$(cat "$FAKE_CODEX_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT"
cat > "${FAKE_CODEX_STDIN_LOG:?}.$count"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Complete the fake task.

## Tasks

### Task 1: Fake task
- File: README.md
- Completion criteria:
  - [ ] fake criterion
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
- [x] Task 1: Fake task - no changes needed

## Completion criteria status
- [x] fake criterion
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critic

## Notes
none

VERDICT: PASS
OUT
    ;;
  *)
    echo "unexpected codex invocation: $count" >&2
    exit 1
    ;;
esac
FAKE_CODEX
chmod +x "$BIN_DIR/codex"

mkfifo "$STDIN_FIFO"
( sleep 60 > "$STDIN_FIFO" ) &
STDIN_PID="$!"

set +e
COMMIT_ON_PASS=0 \
HOME="$FAKE_HOME" \
PATH="$BIN_DIR:$PATH" \
EDITOR="$BIN_DIR/fake-editor" \
EDITOR_LOG="$EDITOR_LOG" \
FAKE_CODEX_COUNT="$CODEX_COUNT" \
FAKE_CODEX_STDIN_LOG="$CODEX_STDIN_LOG" \
timeout 20 bash "$ROOT_DIR/loop.sh" run --project "$PROJECT_DIR" --iterations 1 --cli codex \
  < "$STDIN_FIFO" > "$OUTPUT_FILE" 2>&1
status=$?
set -e

kill "$STDIN_PID" 2>/dev/null || true
wait "$STDIN_PID" 2>/dev/null || true
STDIN_PID=""

if [[ "$status" -eq 124 ]]; then
  fail "explicit run hung waiting for stdin"
fi
if [[ "$status" -ne 0 ]]; then
  fail "explicit run exited with status $status"
fi

if grep -Eqi 'Approve \(y/e/n\)|Please review and approve|enter y, e, or n|\by/e/n\b' "$OUTPUT_FILE"; then
  fail "explicit run printed a human approval prompt"
fi

if [[ -s "$EDITOR_LOG" ]]; then
  fail "explicit run invoked EDITOR"
fi

if [[ "$(cat "$CODEX_COUNT")" != "4" ]]; then
  fail "expected 4 fake codex invocations"
fi

echo "PASS: explicit run did not prompt, invoke editor, or block on stdin"
