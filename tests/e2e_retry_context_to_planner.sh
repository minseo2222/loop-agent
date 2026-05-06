#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"

cat > "$FAKE_HOME/.codex/auth.json" <<'JSON'
{}
JSON

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
chmod +x "$FAKE_BIN/codex"

cat > "$PROJECT_DIR/README.md" <<'MD'
# Temporary Project
MD

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 8.3: Feed bounded retry context to Planner
  - Files:
    - README.md
  - Depends: none
  - Fail count: 3
  - Last failure summary: Plan Critic failure; verdict=FAIL; status=scope too broad; evidence=.loop-agent/evidence/loop-4/plan_critique.md
  - Evidence path: .loop-agent/evidence/loop-4/plan_critique.md
  - Full verify log: DO_NOT_COPY_VERIFY_LOG
  - Completion criteria:
    - [ ] Planner prompt includes fail count.
    - [ ] Planner prompt includes last failure summary.
    - [ ] Planner prompt includes evidence path.
    - [ ] verify: `true`
MD

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" add README.md .loop-agent/backlog.md
git -C "$PROJECT_DIR" commit -q -m "initial"

set +e
HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" COMMIT_ON_PASS=0 "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" >"$TMP_DIR/run.stdout" 2>"$TMP_DIR/run.stderr"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "Expected fake codex to stop after Planner render."
  exit 1
fi

CURRENT_TASK="$PROJECT_DIR/.loop-agent/current_task.md"
PLANNER_RENDERED="$PROJECT_DIR/.loop-agent/planner_rendered.md"

test -f "$CURRENT_TASK"
test -f "$PLANNER_RENDERED"

grep -F -- "- Fail count: 3" "$CURRENT_TASK"
grep -F -- "- Last failure summary: Plan Critic failure; verdict=FAIL; status=scope too broad; evidence=.loop-agent/evidence/loop-4/plan_critique.md" "$CURRENT_TASK"
grep -F -- "- Evidence path: .loop-agent/evidence/loop-4/plan_critique.md" "$CURRENT_TASK"
grep -F -- "Retry context (bounded)" "$PLANNER_RENDERED"
grep -F -- 'Plan only within the backlog `Files:` list.' "$PLANNER_RENDERED"
grep -F -- 'Do not pull full diffs, full logs, or unbounded evidence into the plan.' "$PLANNER_RENDERED"

if grep -F -- "DO_NOT_COPY_VERIFY_LOG" "$CURRENT_TASK" "$PLANNER_RENDERED"; then
  echo "Unbounded verify log was copied into Planner context."
  exit 1
fi
