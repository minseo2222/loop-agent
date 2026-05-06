#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Test Backlog

- [ ] Task 1.1: Deterministic failure
  - Files: `target.txt`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] verify: `true`
BACKLOG
printf 'initial\n' > "$PROJECT_DIR/target.txt"

cat > "$FAKE_BIN/envsubst" <<'ENVEOF'
#!/usr/bin/env bash
cat
ENVEOF

cat > "$FAKE_BIN/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
count=0
if [[ -f "$FAKE_CODEX_COUNT" ]]; then
  count="$(cat "$FAKE_CODEX_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT"

if (( count % 2 == 1 )); then
  cat <<'PLAN'
# Plan

## Goal
Trigger a deterministic plan critic failure.

## Tasks

### Task 1: No-op
- File: `target.txt`
- What to do: Leave unchanged.
- Completion criteria:
  - [ ] verify: `true`
PLAN
else
  echo "# Plan Review"
  echo
  echo "## Notes"
  echo "failure call $count"
  printf 'HUGE_VERIFY_OUTPUT_SHOULD_NOT_ENTER_BACKLOG%.0s' {1..200}
  echo
  echo
  echo "VERDICT: FAIL"
fi
CODEXEOF

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/envsubst"

(
  cd "$PROJECT_DIR"
  git init -q
  git config user.email "loop-test@example.com"
  git config user.name "Loop Test"
  git add target.txt .loop-agent/backlog.md
  git commit -q -m "init"
)

set +e
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" FAKE_CODEX_COUNT="$TMP_DIR/codex_count" \
  LOOP_MAX_ATTEMPTS=5 COMMIT_ON_PASS=0 bash "$ROOT_DIR/loop.sh" run --iterations 2 --project "$PROJECT_DIR" \
  > "$TMP_DIR/loop.out" 2> "$TMP_DIR/loop.err"
loop_code=$?
set -e

[[ "$loop_code" -ne 0 ]] || fail "loop unexpectedly passed"

BACKLOG_FILE="$PROJECT_DIR/.loop-agent/backlog.md"
summary_count="$(grep -c '^  - Last failure summary:' "$BACKLOG_FILE" || true)"
[[ "$summary_count" == "1" ]] || fail "expected one Last failure summary line, got $summary_count"

evidence_count="$(grep -c '^  - Evidence path:' "$BACKLOG_FILE" || true)"
[[ "$evidence_count" == "1" ]] || fail "expected one Evidence path line, got $evidence_count"

summary_line="$(grep '^  - Last failure summary:' "$BACKLOG_FILE")"
summary_text="${summary_line#*Last failure summary: }"
[[ ${#summary_text} -le 300 ]] || fail "summary exceeds 300 characters: ${#summary_text}"

grep -Fq '.loop-agent/plan_critique.md' "$BACKLOG_FILE" || fail "evidence path missing from backlog"
grep -Fq 'loop=2' "$BACKLOG_FILE" || fail "summary was not updated on second failure"
grep -Fq 'Fail count: 2' "$BACKLOG_FILE" || fail "fail count did not reach 2"

if grep -Fq 'HUGE_VERIFY_OUTPUT_SHOULD_NOT_ENTER_BACKLOG' "$BACKLOG_FILE"; then
  fail "full failure output was copied into backlog"
fi

echo "PASS"
