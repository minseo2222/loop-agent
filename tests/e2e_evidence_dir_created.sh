#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$PROJECT_DIR/.loop-agent" "$BIN_DIR"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [ ] Task 1.1: Evidence directory test
  - Depends: none
  - Files:
    - work.txt
  - Completion criteria:
    - [ ] verify: `test -f work.txt`
  - Fail count: 0
BACKLOG

cat > "$BIN_DIR/gemini" <<'FAKE'
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
echo "$count" > "$count_file"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Tasks

### Task 1: Evidence directory test
- File: work.txt
- What to do: Create work.txt.
- Completion criteria:
  - [ ] verify: `test -f work.txt`
OUT
    ;;
  2)
    cat <<'OUT'
VERDICT: PASS

## Notes
none
OUT
    ;;
  3)
    echo "implementation output" > work.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Evidence directory test
OUT
    ;;
  4)
    printf '\nUNAUTHORIZED IMPL CRITIC EDIT\n' >> .loop-agent/progress.txt
    echo "evidence marker" > .loop-agent/evidence/loop-1/agent-note.txt
    cat <<'OUT'
VERDICT: FAIL

## Notes
Intentional failure to exercise rollback.
OUT
    ;;
  *)
    echo "unexpected fake gemini call: $count" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$BIN_DIR/gemini"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" config core.autocrlf false
git -C "$PROJECT_DIR" add .loop-agent/backlog.md
git -C "$PROJECT_DIR" commit -q -m "initial backlog"

set +e
PATH="$BIN_DIR:$PATH" \
HOME="$TMP_DIR/home" \
FAKE_GEMINI_COUNT="$TMP_DIR/gemini-count" \
LOOP_GEMINI_FLAGS="" \
bash "$REPO_DIR/loop.sh" 1 "$PROJECT_DIR" gemini > "$TMP_DIR/loop.out" 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "expected loop.sh to fail after intentional Impl Critic FAIL" >&2
  cat "$TMP_DIR/loop.out" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_DIR/.loop-agent/evidence/loop-1" ]]; then
  echo "missing evidence directory" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/.loop-agent/evidence/loop-1/agent-note.txt" ]]; then
  echo "evidence marker was removed by restore or rollback" >&2
  exit 1
fi

if ! grep -q "Evidence: .loop-agent/evidence/loop-1/" "$PROJECT_DIR/.loop-agent/progress.txt"; then
  echo "progress.txt does not record evidence path" >&2
  exit 1
fi

if grep -q "UNAUTHORIZED IMPL CRITIC EDIT" "$PROJECT_DIR/.loop-agent/progress.txt"; then
  echo "protected progress.txt edit was not restored" >&2
  exit 1
fi

for state_file in current_task.md progress.txt plan.md plan_critique.md impl_summary.md impl_critique.md; do
  if [[ ! -f "$PROJECT_DIR/.loop-agent/$state_file" ]]; then
    echo "missing state file at .loop-agent/$state_file" >&2
    exit 1
  fi
done

if [[ -e "$PROJECT_DIR/work.txt" ]]; then
  echo "rollback did not remove implementation file" >&2
  exit 1
fi
