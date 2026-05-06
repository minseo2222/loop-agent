#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "expected '$text' in $file"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    fail "did not expect '$text' in $file"
  fi
}

prepare_loop_agent() {
  local loop_dir="$1"
  mkdir -p "$loop_dir/agents"
  cp "$ROOT_DIR/loop.sh" "$loop_dir/loop.sh"
  cp "$ROOT_DIR/backlog_manager.py" "$loop_dir/backlog_manager.py"
  chmod +x "$loop_dir/loop.sh"

  printf 'ROLE: Planner\n' > "$loop_dir/agents/planner.md"
  printf 'ROLE: Plan Critic\n' > "$loop_dir/agents/plan_critic.md"
  printf 'ROLE: Implementer\n' > "$loop_dir/agents/implementer.md"
  printf 'ROLE: Impl Critic\n' > "$loop_dir/agents/impl_critic.md"
}

prepare_fake_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$fake_bin/envsubst"

  cat > "$fake_bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" != "exec" ]]; then
  echo "fake codex supports exec only" >&2
  exit 1
fi

prompt="$(cat)"
case "$prompt" in
  *"ROLE: Planner"*)
    cat <<'OUT'
# Plan

## Goal
Exercise verify extraction.

## Tasks

### Task 1: Do the work
- File: implementer_ran
- What to do: Create the marker.
- Completion criteria:
  - [ ] Marker exists.
OUT
    ;;
  *"ROLE: Plan Critic"*)
    cat <<'OUT'
VERDICT: PASS

## Notes
none
OUT
    ;;
  *"ROLE: Implementer"*)
    printf 'ran\n' > implementer_ran
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Do the work
OUT
    ;;
  *"ROLE: Impl Critic"*)
    cat <<'OUT'
VERDICT: PASS

## Notes
none
OUT
    ;;
  *)
    echo "unknown prompt" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fake_bin/codex"
}

write_backlog() {
  local project_dir="$1"
  local criteria="$2"
  mkdir -p "$project_dir/.loop-agent"
  {
    echo "# Backlog"
    echo ""
    echo "- [ ] Task 1.1: Verify extraction"
    echo "  - Description: Exercise verify extraction."
    echo "  - Files: implementer_ran"
    echo "  - Depends: none"
    echo "  - Fail count: 0"
    echo "  - Completion criteria:"
    printf '%s\n' "$criteria"
  } > "$project_dir/.loop-agent/backlog.md"
}

run_loop() {
  local loop_dir="$1"
  local project_dir="$2"
  local fake_bin="$3"
  local home_dir="$4"
  local output_file="$5"

  mkdir -p "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  git -C "$project_dir" init -q
  git -C "$project_dir" config user.email "test@example.com"
  git -C "$project_dir" config user.name "Test User"

  HOME="$home_dir" PATH="$fake_bin:$PATH" COMMIT_ON_PASS=0 \
    "$loop_dir/loop.sh" 1 "$project_dir" codex > "$output_file" 2>&1
}

assert_verify_commands() {
  local project_dir="$1"
  local expected_file="$2"
  local verify_file="$project_dir/.loop-agent/evidence/loop-1/verify_commands.txt"
  local check_file="$project_dir/.loop-agent/evidence/loop-1/verify_commands_check.txt"
  local normalized_file="$project_dir/.loop-agent/evidence/loop-1/verify_commands.normalized.txt"

  assert_file "$verify_file"
  assert_file "$check_file"
  tr -d '\r' < "$verify_file" > "$normalized_file"
  diff -u "$expected_file" "$normalized_file"
  assert_contains "$check_file" "RESULT: PASS"
}

run_success_case() {
  local name="$1"
  local criteria="$2"
  local expected="$3"
  local case_dir="$TMP_DIR/$name"
  local loop_dir="$case_dir/loop-agent"
  local project_dir="$case_dir/project"
  local fake_bin="$case_dir/fake-bin"
  local home_dir="$case_dir/home"
  local output_file="$case_dir/output.txt"
  local expected_file="$case_dir/expected.txt"

  mkdir -p "$loop_dir" "$project_dir"
  prepare_loop_agent "$loop_dir"
  prepare_fake_bin "$fake_bin"
  write_backlog "$project_dir" "$criteria"
  printf '%s\n' "$expected" > "$expected_file"

  if ! run_loop "$loop_dir" "$project_dir" "$fake_bin" "$home_dir" "$output_file"; then
    cat "$output_file" >&2
    fail "$name loop run failed"
  fi
  assert_verify_commands "$project_dir" "$expected_file"
  assert_file "$project_dir/implementer_ran"
}

run_success_case \
  "single" \
  "    - [ ] verify: \`echo single check\`" \
  "echo single check"

run_success_case \
  "multiple" \
  "    - [ ] verify: \`echo first check\`
    - [ ] verify: \`echo second check\`" \
  "echo first check
echo second check"

missing_dir="$TMP_DIR/missing"
missing_loop="$missing_dir/loop-agent"
missing_project="$missing_dir/project"
missing_fake_bin="$missing_dir/fake-bin"
missing_home="$missing_dir/home"
missing_output="$missing_dir/output.txt"
mkdir -p "$missing_loop" "$missing_project"
prepare_loop_agent "$missing_loop"
prepare_fake_bin "$missing_fake_bin"
write_backlog "$missing_project" "    - [ ] Marker exists."

set +e
run_loop "$missing_loop" "$missing_project" "$missing_fake_bin" "$missing_home" "$missing_output"
missing_status=$?
set -e

[[ "$missing_status" -ne 0 ]] || fail "missing verify command should fail"
assert_file "$missing_project/.loop-agent/evidence/loop-1/verify_commands.txt"
assert_file "$missing_project/.loop-agent/evidence/loop-1/verify_commands_check.txt"
assert_contains "$missing_project/.loop-agent/evidence/loop-1/verify_commands_check.txt" "RESULT: FAIL"
assert_contains "$missing_project/.loop-agent/evidence/loop-1/verify_commands_check.txt" "REASON: verify command extraction failed"
assert_contains "$missing_project/.loop-agent/progress.txt" "Verify command extraction BLOCKED"
assert_not_contains "$missing_output" "Phase 3"
[[ ! -f "$missing_project/implementer_ran" ]] || fail "Implementer ran despite missing verify command"

echo "PASS: verify command extraction e2e"
