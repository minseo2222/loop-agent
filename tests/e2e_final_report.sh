#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/project"
STATE="$PROJECT/.loop-agent"
mkdir -p "$STATE/proposals" "$STATE/evidence/loop_1_task_1.1" "$STATE/evidence/loop_2_task_2.1"
git -C "$PROJECT" init -q
git -C "$PROJECT" config core.autocrlf false
git -C "$PROJECT" config user.email "loop-agent@example.com"
git -C "$PROJECT" config user.name "Loop Agent"
printf '%s\n' "final report fixture" > "$PROJECT/work.txt"
git -C "$PROJECT" add work.txt
git -C "$PROJECT" commit -q -m "Task 1.1"
PASS_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"

cat > "$STATE/events.jsonl" <<JSONL
{"event":"task_selected","task_id":"Task 1.1","task_name":"Build parser","evidence_rel":".loop-agent/evidence/loop_1_task_1.1/"}
{"event":"verify_result","task_id":"Task 1.1","task_name":"Build parser","status":"PASS","verify_results_path":".loop-agent/evidence/loop_1_task_1.1/verify_results.md"}
{"event":"commit","task_id":"Task 1.1","task_name":"Build parser","status":"PASS","commit_hash":"$PASS_COMMIT","evidence_rel":".loop-agent/evidence/loop_1_task_1.1/"}
{"event":"decision","task_id":"Task 1.1","task_name":"Build parser","outcome":"PASS","stage":"final_decision:PASS","evidence_rel":".loop-agent/evidence/loop_1_task_1.1/"}
{"event":"verify_result","task_id":"Task 2.1","task_name":"Fix output","status":"FAIL","verify_results_path":".loop-agent/evidence/loop_2_task_2.1/verify_results.md"}
{"event":"rollback","task_id":"Task 2.1","task_name":"Fix output","status":"PASS","reason":"Impl Critic FAIL - discard partial implementation","evidence_rel":".loop-agent/evidence/loop_2_task_2.1/"}
{"event":"decision","task_id":"Task 2.1","task_name":"Fix output","outcome":"FAIL","stage":"final_decision:FAIL","evidence_rel":".loop-agent/evidence/loop_2_task_2.1/"}
JSONL

cat > "$STATE/backlog.md" <<MD
- [x] Task 1.1: Build parser
  - Commit: $PASS_COMMIT
  - Evidence: .loop-agent/evidence/loop_1_task_1.1/pass_result.md
- [ ] Task 2.1: Fix output
  - Fail count: 2
  - Last failure: Impl Critic FAIL
  - Failure evidence: .loop-agent/evidence/loop_2_task_2.1/impl_fail_reason.md
- [!] Task 3.1: Split large task
  - Status: BLOCKED
  - Blocked reason: Scope expansion proposal requires review before more implementation.
  - Evidence: .loop-agent/evidence/loop_3_task_3.1/proposal_verdict.md
MD

cat > "$STATE/proposals/scope_expand_loop_3_Task_3.1.md" <<'MD'
# Scope Expansion Proposal
MD

cat > "$STATE/progress_window.md" <<'MD'
# Recent Progress

This file intentionally contains none of the required report facts.
MD

python "$ROOT/scripts/summarize_events.py" \
  --project "$PROJECT" \
  --state-dir "$STATE" \
  --output "$STATE/report.md"

REPORT="$STATE/report.md"

assert_contains() {
  local expected="$1"
  if ! grep -Fq "$expected" "$REPORT"; then
    echo "missing expected report text: $expected" >&2
    echo "--- report ---" >&2
    cat "$REPORT" >&2
    exit 1
  fi
}

assert_contains "## Completed tasks"
assert_contains "Task 1.1 - Build parser"
assert_contains "## Commit hashes"
assert_contains "$PASS_COMMIT"
assert_contains "## Failed attempts"
assert_contains "Task 2.1 - Fix output: verify failed"
assert_contains "Task 2.1 - Fix output: fail count 2; Impl Critic FAIL"
assert_contains "## Blocked tasks"
assert_contains "Task 3.1 - Split large task: Scope expansion proposal requires review before more implementation."
assert_contains "## Proposal files"
assert_contains "proposals/scope_expand_loop_3_Task_3.1.md"
assert_contains "## Evidence references"
assert_contains ".loop-agent/evidence/loop_1_task_1.1/"
assert_contains ".loop-agent/evidence/loop_2_task_2.1/"
assert_contains ".loop-agent/evidence/loop_3_task_3.1/"
assert_contains "## Latest progress window"
assert_contains ".loop-agent/progress_window.md"

if grep -Fq "intentionally contains" "$REPORT"; then
  echo "report must not parse progress_window.md contents as source truth" >&2
  exit 1
fi

grep -Fq "summarize_events.py" "$ROOT/loop.sh"
grep -Fq "generate_final_report" "$ROOT/loop.sh"
