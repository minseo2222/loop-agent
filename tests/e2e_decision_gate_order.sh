#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fail_with_log() {
  local message="$1"
  local log="$2"
  echo "FAIL: $message" >&2
  if [[ -f "$log" ]]; then
    echo "--- log tail ---" >&2
    tail -80 "$log" >&2
  fi
  exit 1
}

write_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$FAKE_STATE_DIR"
count_file="$FAKE_STATE_DIR/count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(<"$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'PLAN'
# Plan

## Goal
Exercise decision gate order.

## Tasks

### Task 1: Scenario task
- File: app.txt
- What to do: Change app.txt.
- Completion criteria:
  - [ ] verify: `test -f app.txt`

VERDICT: PASS
PLAN
    ;;
  2)
    cat <<'PLAN_CRITIQUE'
# Plan Review

## Notes
none

VERDICT: PASS
PLAN_CRITIQUE
    ;;
  3)
    case "$SCENARIO" in
      backlog_mutation)
        printf 'implemented\n' > app.txt
        printf '\nagent mutation\n' >> .loop-agent/backlog.md
        ;;
      out_of_scope)
        printf 'implemented\n' > app.txt
        printf 'outside\n' > extra.txt
        ;;
      verify_failure|malformed|blocked|pass)
        printf 'implemented\n' > app.txt
        ;;
      *)
        echo "unknown scenario: $SCENARIO" >&2
        exit 2
        ;;
    esac
    cat <<'SUMMARY'
# Implementation Summary

## Tasks completed
- [x] Task 1: Scenario task - changed app.txt

## Completion criteria status
- [x] verify attempted
SUMMARY
    ;;
  4)
    case "$SCENARIO" in
      malformed)
        cat <<'BAD_VERDICT'
# Impl Critique

## Notes
invalid verdict

VERDICT: MAYBE
BAD_VERDICT
        ;;
      blocked)
        cat <<'BLOCKED_VERDICT'
# Impl Critique

## Notes
blocked by critic

VERDICT: BLOCKED
BLOCKED_VERDICT
        ;;
      *)
        cat <<'PASS_VERDICT'
# Impl Critique

## Notes
none

VERDICT: PASS
PASS_VERDICT
        ;;
    esac
    ;;
  *)
    cat <<'DEFAULT_PASS'
# Extra Call

VERDICT: PASS
DEFAULT_PASS
    ;;
esac
FAKE_CODEX
  chmod +x "$bin_dir/codex"
}

write_backlog() {
  local project="$1"
  local verify_cmd="$2"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<BACKLOG
# Backlog

## Tasks

- [ ] Task 1.1: Decision gate scenario
  - Files:
    - app.txt
  - Depends: none
  - Completion criteria:
    - [ ] app.txt is changed
    - [ ] verify: \`$verify_cmd\`
  - Fail count: 0
BACKLOG
}

run_scenario() {
  local scenario="$1"
  local verify_cmd="$2"
  local project="$TMP_ROOT/$scenario/project"
  local fake_bin="$TMP_ROOT/$scenario/bin"
  local fake_state="$TMP_ROOT/$scenario/fake-state"
  local fake_home="$TMP_ROOT/$scenario/home"
  local log="$TMP_ROOT/$scenario/run.log"

  mkdir -p "$project" "$fake_state" "$fake_home/.codex"
  printf '{}\n' > "$fake_home/.codex/auth.json"
  write_fake_codex "$fake_bin"
  write_backlog "$project" "$verify_cmd"

  set +e
  PATH="$fake_bin:$PATH" \
  HOME="$fake_home" \
  SCENARIO="$scenario" \
  FAKE_STATE_DIR="$fake_state" \
  GIT_AUTHOR_NAME="Loop Test" \
  GIT_AUTHOR_EMAIL="loop-test@example.com" \
  GIT_COMMITTER_NAME="Loop Test" \
  GIT_COMMITTER_EMAIL="loop-test@example.com" \
    bash "$ROOT/loop.sh" run --iterations 1 --project "$project" > "$log" 2>&1
  local code=$?
  set -e

  printf '%s\n' "$project|$log|$code"
}

has_pass_commit() {
  local project="$1"
  git -C "$project" log --format=%s 2>/dev/null | grep -q '^loop-agent: PASS '
}

assert_rolled_back() {
  local project="$1"
  [[ ! -e "$project/app.txt" ]] || fail "app.txt was not rolled back in $project"
  [[ ! -e "$project/extra.txt" ]] || fail "extra.txt was not rolled back in $project"
}

assert_negative() {
  local scenario="$1"
  local verify_cmd="$2"
  local result project log code
  result="$(run_scenario "$scenario" "$verify_cmd")"
  IFS='|' read -r project log code <<< "$result"

  [[ "$code" -ne 0 ]] || fail_with_log "$scenario unexpectedly exited 0" "$log"
  ! has_pass_commit "$project" || fail_with_log "$scenario created a PASS commit" "$log"
  assert_rolled_back "$project"
}

assert_positive_pass() {
  local result project log code
  result="$(run_scenario pass 'test -f app.txt')"
  IFS='|' read -r project log code <<< "$result"

  [[ "$code" -eq 0 ]] || fail_with_log "pass scenario failed with exit $code" "$log"
  has_pass_commit "$project" || fail_with_log "pass scenario did not create a PASS commit" "$log"
  [[ -f "$project/app.txt" ]] || fail "pass scenario did not keep app.txt"
}

assert_negative backlog_mutation 'test -f app.txt'
assert_negative out_of_scope 'test -f app.txt'
assert_negative verify_failure 'false'
assert_negative malformed 'test -f app.txt'
assert_negative blocked 'test -f app.txt'
assert_positive_pass

echo "PASS: decision gate order"
