#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
FAKE_BIN="$TMP/bin"
FAKE_HOME="$TMP/home"
PROMPTS="$TMP/prompts"
CALLS="$TMP/calls.txt"
LOG="$TMP/loop.log"

fail() {
  echo "$1" >&2
  if [[ -f "$LOG" ]]; then
    cat "$LOG" >&2
  fi
  exit 1
}

mkdir -p "$PROJECT/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex" "$PROMPTS"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$PROJECT/.gitignore" <<'EOF'
.loop-agent/
EOF
cat > "$PROJECT/allowed.txt" <<'EOF'
original
EOF
cat > "$PROJECT/excluded.txt" <<'EOF'
original
EOF
cat > "$PROJECT/.loop-agent/backlog.md" <<'EOF'
# Backlog

- [ ] Task 1.1: Stay in scope
  - Files:
    - allowed.txt
  - Depends: none
  - verify: `bash -c "test -f allowed.txt"`
  - Completion criteria:
    - Only allowed.txt may be changed.
  - Fail count: 0
EOF

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -q -m "initial"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
count=0
if [[ -f "$LOOP_FAKE_CODEX_CALLS" ]]; then
  count="$(cat "$LOOP_FAKE_CODEX_CALLS")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$LOOP_FAKE_CODEX_CALLS"
printf '%s\n' "$prompt" > "$LOOP_FAKE_PROMPT_DIR/call-${count}.md"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Exercise out-of-scope detection.

## Tasks

### Task 1: Stay in scope
- File: allowed.txt
- What to do: Keep changes scoped.
- Completion criteria:
  - [ ] verify: `bash -c "test -f allowed.txt"`
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
    printf 'changed\n' > excluded.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Stay in scope - changed an excluded file for test coverage.
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critic

## Notes
Fake critic returns PASS so the shell scope gate remains authoritative.

VERDICT: PASS
OUT
    ;;
  *)
    echo "Unexpected fake codex call: $count" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/codex"

set +e
PATH="$FAKE_BIN:$PATH" \
HOME="$FAKE_HOME" \
LOOP_FAKE_CODEX_CALLS="$CALLS" \
LOOP_FAKE_PROMPT_DIR="$PROMPTS" \
  bash "$ROOT/loop.sh" run --iterations 1 --project "$PROJECT" --cli codex > "$LOG" 2>&1
code=$?
set -e

if [[ "$code" -eq 0 ]]; then
  fail "Expected loop.sh to exit non-zero because no PASS is allowed."
fi

EVIDENCE="$PROJECT/.loop-agent/evidence/loop-1"
[[ -f "$EVIDENCE/out_of_scope.txt" ]] || fail "missing out_of_scope.txt"
[[ -f "$EVIDENCE/scope_check.txt" ]] || fail "missing scope_check.txt"

grep -qx 'excluded.txt' "$EVIDENCE/out_of_scope.txt"
grep -q '^RESULT: OUT_OF_SCOPE$' "$EVIDENCE/scope_check.txt"
grep -q '^TASK: Task 1.1$' "$EVIDENCE/scope_check.txt"
grep -q '^ALLOWED_COUNT: 1$' "$EVIDENCE/scope_check.txt"
grep -q '^CHANGED_COUNT: 1$' "$EVIDENCE/scope_check.txt"
grep -q '^OUT_OF_SCOPE_COUNT: 1$' "$EVIDENCE/scope_check.txt"
grep -q '^excluded.txt$' "$EVIDENCE/scope_check.txt"

grep -q 'RESULT: OUT_OF_SCOPE' "$PROJECT/.loop-agent/progress.txt"
grep -q 'Evidence: .loop-agent/evidence/loop-1/' "$PROJECT/.loop-agent/progress.txt"

grep -q 'scope_check.txt' "$PROJECT/.loop-agent/impl_critic_rendered.md"
grep -q 'out_of_scope.txt' "$PROJECT/.loop-agent/impl_critic_rendered.md"
grep -q 'RESULT: OUT_OF_SCOPE' "$PROJECT/.loop-agent/impl_critic_rendered.md"
grep -q '^excluded.txt$' "$PROJECT/.loop-agent/impl_critic_rendered.md"

[[ "$(cat "$CALLS")" == "4" ]] || { echo "Impl Critic was not run after scope detection" >&2; exit 1; }
grep -qx 'original' "$PROJECT/excluded.txt" || { echo "excluded.txt was not rolled back" >&2; exit 1; }

if git -C "$PROJECT" log --oneline --grep='loop-agent: PASS' | grep -q .; then
  echo "Unexpected PASS commit found." >&2
  git -C "$PROJECT" log --oneline --grep='loop-agent: PASS' >&2
  exit 1
fi

echo "PASS"
