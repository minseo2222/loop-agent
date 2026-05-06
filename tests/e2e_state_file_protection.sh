#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_SH="$ROOT_DIR/loop.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$bin_dir/envsubst"

  cat > "$bin_dir/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
script="${1:-}"
shift || true
case "$(basename "$script")" in
  backlog_manager.py)
    cmd="${1:-}"
    case "$cmd" in
      lint) exit 0 ;;
      status) echo '{"complete": false, "pending": 1, "blocked": 0}' ;;
      progress) echo 'pending: 1' ;;
      next) echo '{"id": "Task 1", "name": "State protection fixture"}' ;;
      semantic-snapshot)
        file="${2:-}"
        if [[ -f "$file" ]]; then cksum "$file"; else echo "__MISSING__"; fi
        ;;
      fail|complete) echo 'OK' ;;
      compact) echo 'NO_CHANGE: none' ;;
      *) echo '{}' ;;
    esac
    ;;
  progress_window.py)
    file="${1:-}"
    if [[ -f "$file" ]]; then cat "$file"; fi
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$bin_dir/python3"

  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
count_file="$LOOP_STATE_DIR/codex_stage_count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

case "${SCENARIO:-}" in
  progress)
    if [[ "$count" -eq 3 ]]; then echo 'bad-progress' >> "$LOOP_PROGRESS"; fi
    ;;
  current_task)
    if [[ "$count" -eq 3 ]]; then echo 'bad-current' > "$LOOP_CURRENT_TASK"; fi
    ;;
  plan_wrong_stage)
    if [[ "$count" -eq 2 ]]; then echo 'bad-plan' >> "$LOOP_PLAN"; fi
    ;;
  impl_summary_wrong_stage)
    if [[ "$count" -eq 4 ]]; then echo 'bad-impl-summary' >> "$LOOP_IMPL_SUMMARY"; fi
    ;;
esac

case "$count" in
  1)
    printf '# Plan\n\n## Goal\nFixture plan\n'
    ;;
  2)
    printf '# Plan Review\n\n## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  3)
    printf '# Implementation Summary\n\n## Tasks completed\n- [x] Task 1: Fixture\n'
    ;;
  4)
    printf '# Impl Critic\n\n## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  *)
    printf 'VERDICT: PASS\n'
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1: State protection fixture
  - Files: `fixture.txt`
  - Depends on: none
  - Status: pending
  - Fail count: 0
MD
  cat > "$project/.loop-agent/progress.txt" <<'MD'
# Loop Agent Progress
Project: fixture
Started: fixture
---
MD
}

run_case() {
  local scenario="$1"
  local bad_text="$2"
  local protected_file="$3"
  local case_dir="$TMP_ROOT/$scenario"
  local bin_dir="$case_dir/bin"
  local project="$case_dir/project"
  local home_dir="$case_dir/home"
  local output="$case_dir/output.txt"

  mkdir -p "$case_dir" "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  make_bin "$bin_dir"
  make_project "$project"

  set +e
  PATH="$bin_dir:$PATH" \
  HOME="$home_dir" \
  SCENARIO="$scenario" \
  GIT_AUTHOR_NAME="Loop Test" \
  GIT_AUTHOR_EMAIL="loop-test@example.com" \
  GIT_COMMITTER_NAME="Loop Test" \
  GIT_COMMITTER_EMAIL="loop-test@example.com" \
  bash "$LOOP_SH" run --iterations 1 --project "$project" > "$output" 2>&1
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$scenario: expected loop failure"
    cat "$output"
    exit 1
  fi
  if grep -q "$bad_text" "$project/.loop-agent/$protected_file"; then
    echo "$scenario: protected file was not restored"
    cat "$project/.loop-agent/$protected_file"
    exit 1
  fi
  if ! grep -q "State File Protection Violation" "$project/.loop-agent/progress.txt"; then
    echo "$scenario: progress did not record protection violation"
    cat "$project/.loop-agent/progress.txt"
    exit 1
  fi
  if grep -q "=== Loop 1: PASS ===" "$project/.loop-agent/progress.txt"; then
    echo "$scenario: loop passed after protection violation"
    cat "$project/.loop-agent/progress.txt"
    exit 1
  fi
}

run_case progress bad-progress progress.txt
run_case current_task bad-current current_task.md
run_case plan_wrong_stage bad-plan plan.md
run_case impl_summary_wrong_stage bad-impl-summary impl_summary.md

echo "e2e_state_file_protection: PASS"
