#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/project_factory.sh"

project_dir="$(create_temp_scope_expand_project)"
output_file="$(mktemp)"
second_output_file="$(mktemp)"
evidence_file="$(mktemp)"

cleanup() {
  rm -rf "$project_dir"
  rm -f "$output_file" "$second_output_file" "$evidence_file"
}
trap cleanup EXIT

backlog_file="$project_dir/.loop-agent/backlog.md"
grep -q 'Files: `src/app.txt`' "$backlog_file"
if grep -q 'docs/extra_scope.md' "$backlog_file"; then
  echo "fixture backlog should not include requested extra file" >&2
  exit 1
fi
semantic_before="$(python "$ROOT_DIR/backlog_manager.py" semantic-snapshot "$backlog_file")"
commit_count_before="$(git -C "$project_dir" rev-list --count HEAD)"

set +e
(
  cd "$project_dir"
  PATH="$ROOT_DIR/tests/fake_cli:$PATH" \
    LOOP_FAKE_PROJECT_DIR="$project_dir" \
    LOOP_FAKE_SCENARIO=scope_expand \
    bash "$ROOT_DIR/loop.sh" 1 "$project_dir" codex
) >"$output_file" 2>&1
loop_status=$?
set -e

cat "$output_file" >"$evidence_file"
if [[ -d "$project_dir/.loop-agent" ]]; then
  grep -R "SCOPE_EXPAND\|docs/extra_scope.md" "$project_dir/.loop-agent" >>"$evidence_file" 2>/dev/null || true
fi

grep -q "SCOPE_EXPAND" "$evidence_file"
grep -q "docs/extra_scope.md" "$evidence_file"
if grep -F -- '[!\]' "$backlog_file" "$output_file" "$evidence_file" >/dev/null; then
  echo "malformed blocked marker was written" >&2
  exit 1
fi
progress_file="$project_dir/.loop-agent/progress.txt"
progress_window_file="$project_dir/.loop-agent/progress_window.md"
report_file="$project_dir/.loop-agent/report.md"
events_file="$project_dir/.loop-agent/events.jsonl"
grep -q '^Task: Task .* - ' "$progress_file"
grep -q '^Blocked reason: Scope expansion proposal requires review before more implementation\.' "$progress_file"
grep -q '^Current allowed Files: `src/app.txt`' "$progress_file"
grep -q '^Requested additional files: `docs/extra_scope.md`' "$progress_file"
grep -q '^Evidence directory: \.loop-agent/evidence/loop-1/' "$progress_file"
grep -q '^Verdict source: Impl Critic SCOPE_EXPAND' "$progress_file"
grep -q '^Proposal evidence: \.loop-agent/evidence/loop-1/proposal_verdict\.md' "$progress_file"
grep -q '^Mutation evidence: \.loop-agent/evidence/loop-1/scope_expand_mutation\.md' "$progress_file"
grep -q '^Fail count unchanged: 0' "$progress_file"
grep -q '^Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria' "$progress_file"
grep -q '^Recommended action: Review the scope expansion proposal and manually update backlog\.md Files if appropriate\.' "$progress_file"
grep -q '^- Task: Task .* - ' "$progress_window_file"
grep -q '^- Blocked reason: Scope expansion proposal requires review before more implementation\.' "$progress_window_file"
grep -q '^- Current allowed Files: `src/app.txt`' "$progress_window_file"
grep -q '^- Requested additional files: `docs/extra_scope.md`' "$progress_window_file"
grep -q '^- Evidence directory: \.loop-agent/evidence/loop-1/' "$progress_window_file"
grep -q '^- Verdict source: Impl Critic SCOPE_EXPAND' "$progress_window_file"
grep -q '^- Proposal evidence: \.loop-agent/evidence/loop-1/proposal_verdict\.md' "$progress_window_file"
grep -q '^- Mutation evidence: \.loop-agent/evidence/loop-1/scope_expand_mutation\.md' "$progress_window_file"
grep -q '^- Fail count unchanged: 0' "$progress_window_file"
grep -q '^- Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria' "$progress_window_file"
grep -q '^- Recommended action: Review the scope expansion proposal and manually update backlog\.md Files if appropriate\.' "$progress_window_file"
grep -q 'BLOCKED: SCOPE_EXPAND' "$report_file"
grep -q 'Scope expansion proposal requires review before more implementation\.' "$report_file"
grep -q 'docs/extra_scope.md' "$report_file"
grep -q 'fail count unchanged' "$report_file"
EVENTS_FILE="$events_file" python - <<'PY'
import json
import os

events = []
with open(os.environ["EVENTS_FILE"], encoding="utf-8") as f:
    for line in f:
        if line.strip():
            events.append(json.loads(line))

blocked = [
    event for event in events
    if event.get("event") == "blocked" and event.get("block_type") == "SCOPE_EXPAND"
]
assert blocked, "missing blocked SCOPE_EXPAND event"
event = blocked[-1]
assert event.get("outcome") == "BLOCKED", event
assert event.get("status") == "BLOCKED", event
assert event.get("task_id", "").startswith("Task "), event
assert event.get("reason") == "Scope expansion proposal requires review before more implementation.", event
assert "docs/extra_scope.md" in event.get("requested_files", ""), event
assert event.get("fail_count_unchanged") is True, event
PY
grep -q '^- \[!\] Task ' "$backlog_file"
grep -q 'Fail count: 0' "$backlog_file"
fail_count_after_first="$(grep -c 'Fail count: 0' "$backlog_file")"
grep -q 'Files: `src/app.txt`' "$backlog_file"
if grep -q 'docs/extra_scope.md' "$backlog_file"; then
  echo "scope expansion file was added to backlog Files" >&2
  cat "$backlog_file" >&2
  exit 1
fi
semantic_after="$(python "$ROOT_DIR/backlog_manager.py" semantic-snapshot "$backlog_file")"
if [[ "$semantic_after" != "$semantic_before" ]]; then
  echo "backlog semantic fields changed during SCOPE_EXPAND block" >&2
  exit 1
fi
commit_count_after="$(git -C "$project_dir" rev-list --count HEAD)"
if [[ "$commit_count_after" != "$commit_count_before" ]]; then
  echo "SCOPE_EXPAND created a PASS commit" >&2
  exit 1
fi
if [[ -e "$project_dir/docs/extra_scope.md" ]]; then
  echo "implementation changes were not rolled back" >&2
  exit 1
fi
project_status="$(
  git -C "$project_dir" status --porcelain --untracked-files=all |
    grep -vE '^[ MADRCU?!]{2} \.loop-agent(/|$)|^[ MADRCU?!]{2} loop-agent(/|$)|^[ MADRCU?!]{2} \.gitignore$' || true
)"
if [[ -n "$project_status" ]]; then
  echo "project changes remained after SCOPE_EXPAND rollback" >&2
  echo "$project_status" >&2
  exit 1
fi

proposal_count_before="$(
  find "$project_dir/.loop-agent/proposals" -type f -name 'scope_expand_loop_*' 2>/dev/null |
    wc -l |
    tr -d ' '
)"
set +e
(
  cd "$project_dir"
  PATH="$ROOT_DIR/tests/fake_cli:$PATH" \
    LOOP_FAKE_PROJECT_DIR="$project_dir" \
    LOOP_FAKE_SCENARIO=scope_expand \
    bash "$ROOT_DIR/loop.sh" 1 "$project_dir" codex
) >"$second_output_file" 2>&1
second_loop_status=$?
set -e
if [[ "$second_loop_status" -eq 127 ]]; then
  echo "second loop.sh run could not run" >&2
  cat "$second_output_file" >&2
  exit 1
fi
if grep -q "Scope expansion requested" "$second_output_file"; then
  echo "blocked SCOPE_EXPAND task was retried automatically" >&2
  cat "$second_output_file" >&2
  exit 1
fi
if grep -F -- '[!\]' "$backlog_file" "$second_output_file" >/dev/null; then
  echo "malformed blocked marker was written on second run" >&2
  exit 1
fi
grep -q '^- \[!\] Task ' "$backlog_file"
if [[ "$(grep -c 'Fail count: 0' "$backlog_file")" != "$fail_count_after_first" ]]; then
  echo "blocked fail count changed on second run" >&2
  exit 1
fi
proposal_count_after="$(
  find "$project_dir/.loop-agent/proposals" -type f -name 'scope_expand_loop_*' 2>/dev/null |
    wc -l |
    tr -d ' '
)"
if [[ "$proposal_count_after" != "$proposal_count_before" ]]; then
  echo "second run created another scope expansion proposal" >&2
  exit 1
fi
if [[ "$(git -C "$project_dir" rev-list --count HEAD)" != "$commit_count_before" ]]; then
  echo "second run created a PASS commit" >&2
  exit 1
fi

if [[ "$loop_status" -eq 127 ]]; then
  echo "loop.sh could not run" >&2
  cat "$output_file" >&2
  exit 1
fi
