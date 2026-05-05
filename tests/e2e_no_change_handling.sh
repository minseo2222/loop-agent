#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN"

cat > "$FAKE_BIN/gemini" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
  echo "fake-gemini 1.0.0"
  exit 0
fi

input="$(cat)"
state_dir="$PWD/.loop-agent"
count_file="$state_dir/fake_gemini_count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise no-change handling.

## Tasks

### Task 1: No-change implementation
- File: README.md
- What to do: Make a test change.
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
- [x] Task 1: No-change implementation - claimed done without edits

## Completion criteria status
Task 1:
- [x] verify: `true`
OUT
    ;;
  4)
    cat <<'OUT'
# Implementation Critique

## Notes
Claims PASS even though no files changed.

VERDICT: PASS
OUT
    ;;
  *)
    echo "Unexpected fake gemini call $count" >&2
    exit 1
    ;;
esac

printf '%s' "$input" > /dev/null
SH
chmod +x "$FAKE_BIN/gemini"

cat > "$PROJECT_DIR/README.md" <<'EOF_README'
initial
EOF_README

cat > "$PROJECT_DIR/.gitignore" <<'EOF_GITIGNORE'
.loop-agent/
EOF_GITIGNORE

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'EOF_BACKLOG'
# Backlog

- [ ] Task 1.1: No-change implementation
  - Depends: none
  - Files:
    - README.md
  - Completion criteria:
    - verify: `true`
  - Fail count: 0
EOF_BACKLOG

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" add README.md .gitignore
git -C "$PROJECT_DIR" commit -q -m "initial"

set +e
PATH="$FAKE_BIN:$PATH" LOOP_GEMINI_FLAGS="" LOOP_GEMINI_MODEL_FLAG="--model" \
  bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli gemini \
  > "$TMP_DIR/run.stdout" 2> "$TMP_DIR/run.stderr"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Expected loop to exit nonzero when no PASS occurs." >&2
  exit 1
fi

if git -C "$PROJECT_DIR" log --format=%s | grep -q "loop-agent: PASS"; then
  echo "Unexpected PASS commit was created." >&2
  exit 1
fi

if grep -q "^- \[x\] Task 1.1:" "$PROJECT_DIR/.loop-agent/backlog.md"; then
  echo "Backlog task was unexpectedly completed." >&2
  exit 1
fi

changed_file="$PROJECT_DIR/.loop-agent/evidence/loop-1/changed_files_after_implementer.txt"
if [[ ! -f "$changed_file" ]]; then
  echo "Missing changed-files evidence: $changed_file" >&2
  cat "$TMP_DIR/run.stdout" >&2
  cat "$TMP_DIR/run.stderr" >&2
  exit 1
fi

if [[ -s "$changed_file" ]]; then
  echo "Expected changed-files evidence to be empty." >&2
  exit 1
fi

failure_file="$PROJECT_DIR/.loop-agent/evidence/loop-1/no_change_failure.md"
if [[ ! -f "$failure_file" ]]; then
  echo "Missing no-change failure evidence: $failure_file" >&2
  exit 1
fi

if ! grep -q "no project files changed after Implementer" "$failure_file"; then
  echo "No-change failure evidence did not include the expected reason." >&2
  exit 1
fi

if ! grep -q "No-change FAIL" "$PROJECT_DIR/.loop-agent/progress.txt"; then
  echo "progress.txt did not record the no-change failure." >&2
  exit 1
fi

if ! grep -q "No-change Override" "$PROJECT_DIR/.loop-agent/report.md"; then
  echo "report.md did not record the no-change override." >&2
  exit 1
fi
