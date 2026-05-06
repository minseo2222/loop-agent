#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
CAPTURE_DIR="$TMP_DIR/capture"
mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex" "$CAPTURE_DIR"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$PROJECT_DIR/work.txt" <<'EOF'
initial
EOF

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks
- [ ] Task 1.1: Verify evidence prompt
  - Files:
    - work.txt
  - Depends: none
  - Completion criteria:
    - [ ] verify: `printf 'verify evidence ok\n'`
  - Fail count: 0
EOF

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test"
git -C "$PROJECT_DIR" add work.txt
git -C "$PROJECT_DIR" commit -q -m "initial"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
mkdir -p "$FAKE_CAPTURE_DIR"

if grep -q '^# Impl Critic' <<<"$prompt"; then
  printf '%s\n' "$prompt" > "$FAKE_CAPTURE_DIR/impl_critic_prompt.md"
  cat <<'OUT'
# Implementation Review - Loop 1

## Files read
- plan.md
- impl_summary.md
- shell evidence files
- work.txt

## Completion criteria check

### Task 1: Verify evidence prompt
- [x] verify: `printf 'verify evidence ok\n'`: already-run shell result is PASS.

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
OUT
elif grep -q '^# Implementer' <<<"$prompt"; then
  printf 'implemented\n' > work.txt
  cat <<'OUT'
# Implementation Summary - Loop 1

## Files read
- plan.md
- plan_critique.md
- work.txt

## Tasks completed
- [x] Task 1: Verify evidence prompt - updated work.txt.

## Files changed
| File | Action | What changed |
|------|--------|--------------|
| work.txt | modified | Updated test content. |

## Completion criteria status
Task 1:
- [x] verify: `printf 'verify evidence ok\n'` - shell verify attempted by loop.

## Additional files needed
none

## Unrelated issues noticed (not fixed)
none
OUT
elif grep -q '^# Plan Critic' <<<"$prompt"; then
  cat <<'OUT'
# Plan Review - Loop 1

## Notes
none

VERDICT: PASS
OUT
elif grep -q '^# Planner' <<<"$prompt"; then
  cat <<'OUT'
# Plan - Loop 1

## Goal
Render verify evidence for Impl Critic.

## Tasks

### Task 1: Verify evidence prompt
- File: `work.txt`
- What to do: Update the test file.
- Completion criteria:
  - [ ] verify: `printf 'verify evidence ok\n'`
OUT
else
  echo "Unexpected prompt" >&2
  exit 1
fi
EOF
chmod +x "$FAKE_BIN/codex"

LOOP_OUTPUT="$TMP_DIR/loop.out"
if ! HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" FAKE_CAPTURE_DIR="$CAPTURE_DIR" COMMIT_ON_PASS=0 \
  bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex > "$LOOP_OUTPUT" 2>&1; then
  cat "$LOOP_OUTPUT"
  exit 1
fi

PROMPT="$CAPTURE_DIR/impl_critic_prompt.md"
test -f "$PROMPT"

grep -Fq 'verify_results.md' "$PROMPT"
grep -Fq 'verify_exit_codes.txt' "$PROMPT"
grep -Fq '.loop-agent/evidence/loop-1/verify_results.md' "$PROMPT"
grep -Fq '.loop-agent/evidence/loop-1/verify_exit_codes.txt' "$PROMPT"
grep -Fq '### verify_results.md' "$PROMPT"
grep -Fq '### verify_exit_codes.txt' "$PROMPT"
grep -Fq 'Status: PASS' "$PROMPT"
grep -Fq 'command_1=PASS exit=0' "$PROMPT"
grep -Fq 'Shell verify result is authoritative' "$PROMPT"

grep -Fq 'verify_results.md' "$ROOT_DIR/agents/impl_critic.md"
grep -Fq 'verify_exit_codes.txt' "$ROOT_DIR/agents/impl_critic.md"
grep -Fq 'Shell verify result is authoritative' "$ROOT_DIR/agents/impl_critic.md"
if grep -Fqi 'would this pass' "$ROOT_DIR/agents/impl_critic.md"; then
  echo "stale predictive verify wording found in agents/impl_critic.md" >&2
  exit 1
fi
if grep -Fqi 'would this pass' "$PROMPT"; then
  echo "stale predictive verify wording found in rendered Impl Critic prompt" >&2
  exit 1
fi
