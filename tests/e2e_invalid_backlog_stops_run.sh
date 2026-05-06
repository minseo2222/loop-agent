#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
chmod +x "$FAKE_BIN/envsubst"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count_file="${LOOP_FAKE_CLI_LOG}.count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf 'codex invocation %s: %s\n' "$count" "$*" >> "$LOOP_FAKE_CLI_LOG"
cat >/dev/null

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Use the selected task.
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
- [x] Task 1: First task - done
OUT
    ;;
  *)
    cat <<'OUT'
# Implementation Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
esac
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TMP_DIR/home"
export LOOP_FAKE_CLI_LOG="$TMP_DIR/fake_cli.log"
export GIT_AUTHOR_NAME="Loop Test"
export GIT_AUTHOR_EMAIL="loop-test@example.com"
export GIT_COMMITTER_NAME="Loop Test"
export GIT_COMMITTER_EMAIL="loop-test@example.com"
mkdir -p "$HOME/.codex"
printf '{}\n' > "$HOME/.codex/auth.json"

make_project() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  printf 'content\n' > "$project/README.md"
}

INVALID_PROJECT="$TMP_DIR/invalid-project"
make_project "$INVALID_PROJECT"
cat > "$INVALID_PROJECT/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1.1: Broken task
MD

set +e
bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$INVALID_PROJECT" --cli codex > "$TMP_DIR/invalid.out" 2> "$TMP_DIR/invalid.err"
invalid_status=$?
set -e

if [[ "$invalid_status" -eq 0 ]]; then
  echo "Expected invalid backlog run to fail."
  exit 1
fi

if [[ -s "$LOOP_FAKE_CLI_LOG" ]]; then
  echo "Fake CLI was invoked for invalid backlog."
  cat "$LOOP_FAKE_CLI_LOG"
  exit 1
fi

if ! grep -q "Backlog lint failed" "$TMP_DIR/invalid.err"; then
  echo "Expected lint failure header in stderr."
  cat "$TMP_DIR/invalid.err"
  exit 1
fi

if ! grep -q "missing Files" "$TMP_DIR/invalid.err"; then
  echo "Expected lint reason in stderr."
  cat "$TMP_DIR/invalid.err"
  exit 1
fi

VALID_PROJECT="$TMP_DIR/valid-project"
make_project "$VALID_PROJECT"
cat > "$VALID_PROJECT/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1.1: First task
  - Files: README.md
  - Depends: none
  - Completion criteria:
    - [ ] verify: `true`
  - Fail count: 0
MD

rm -f "$LOOP_FAKE_CLI_LOG" "$LOOP_FAKE_CLI_LOG.count"
bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$VALID_PROJECT" --cli codex > "$TMP_DIR/valid.out" 2> "$TMP_DIR/valid.err"

if ! grep -q "codex invocation 1" "$LOOP_FAKE_CLI_LOG"; then
  echo "Expected fake Planner invocation for valid backlog."
  cat "$TMP_DIR/valid.out"
  cat "$TMP_DIR/valid.err"
  exit 1
fi

if ! grep -q "Task ID: Task 1.1" "$VALID_PROJECT/.loop-agent/current_task.md"; then
  echo "Expected valid backlog to select the first task."
  cat "$VALID_PROJECT/.loop-agent/current_task.md"
  exit 1
fi

echo "PASS"
