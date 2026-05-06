#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "expected $file to contain: $text"
}

write_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_file="${CODEX_FAKE_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
cat >/dev/null

case "$count" in
  1)
    cat <<PLAN
# Plan

## Tasks

### Task 1: Change allowed file
- File: \`app.txt\`
- What to do: Change the allowed file.
- Completion criteria:
  - [ ] verify: \`bash verify.sh\`
PLAN
    ;;
  2)
    cat <<CRITIQUE
# Plan Review

## Notes
none

VERDICT: PASS
CRITIQUE
    ;;
  3)
    printf 'changed by implementer\n' > app.txt
    cat <<SUMMARY
# Implementation Summary

## Tasks completed
- [x] Task 1: Change allowed file - changed app.txt

## Completion criteria status
- [x] verify: \`bash verify.sh\`
SUMMARY
    ;;
  4)
    cat <<CRITIQUE
# Impl Critique

## Notes
none

VERDICT: PASS
CRITIQUE
    ;;
  *)
    echo "unexpected codex call $count" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/codex"
}

write_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks

- [ ] Task 1.1: Verify gate sample
  - Depends: none
  - Files:
    - app.txt
  - Completion criteria:
    - verify: `bash verify.sh`
  - Fail count: 0
EOF
}

prepare_project() {
  local project="$1"
  local verify_body="$2"
  mkdir -p "$project"
  printf 'original\n' > "$project/app.txt"
  printf '%s\n' "$verify_body" > "$project/verify.sh"
  chmod +x "$project/verify.sh"
  printf '.loop-agent/\n' > "$project/.gitignore"
  write_backlog "$project"
  git -C "$project" init -q
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" config core.autocrlf false
  git -C "$project" add -A
  git -C "$project" commit -q -m "initial"
}

run_case() {
  local name="$1"
  local verify_body="$2"
  local expected_status="$3"
  local expected_exit="$4"
  local project="$TMP_ROOT/$name/project"
  local bin_dir="$TMP_ROOT/$name/bin"
  local home_dir="$TMP_ROOT/$name/home"
  local output_file="$TMP_ROOT/$name/loop.out"
  local status=0

  mkdir -p "$TMP_ROOT/$name" "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  prepare_project "$project" "$verify_body"
  write_fake_codex "$bin_dir"

  if HOME="$home_dir" PATH="$bin_dir:$PATH" CODEX_FAKE_COUNT_FILE="$TMP_ROOT/$name/count" LOOP_VERIFY_TIMEOUT=1 bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" > "$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -ne 0 ]] || fail "$name: loop unexpectedly returned success"
  [[ "$(cat "$project/app.txt")" == "original" ]] || fail "$name: implementation changes were not rolled back"
  ! git -C "$project" log --format=%s | grep -Fq "loop-agent: PASS" || fail "$name: PASS commit was created"
  assert_contains "$project/.loop-agent/backlog.md" "Fail count: 1"
  [[ -f "$project/.loop-agent/evidence/loop-1/verify_results.md" ]] || fail "$name: verify_results.md missing"
  [[ -f "$project/.loop-agent/evidence/loop-1/verify_exit_codes.txt" ]] || fail "$name: verify_exit_codes.txt missing"
  assert_contains "$project/.loop-agent/evidence/loop-1/verify_results.md" "Status: $expected_status"
  assert_contains "$project/.loop-agent/evidence/loop-1/verify_exit_codes.txt" "$expected_exit"
  assert_contains "$project/.loop-agent/progress.txt" "Final decision: FAIL (shell verify overrides Impl Critic PASS)"
  assert_contains "$project/.loop-agent/progress.txt" "Verify results: .loop-agent/evidence/loop-1/verify_results.md"
  assert_contains "$project/.loop-agent/progress.txt" "Verify exit codes: .loop-agent/evidence/loop-1/verify_exit_codes.txt"
  assert_contains "$project/.loop-agent/report.md" "Final decision: FAIL (shell verify overrides Impl Critic PASS)"
}

run_case "nonzero" 'exit 7' "FAIL" "command_1=FAIL exit=7"
run_case "timeout" 'sleep 2' "TIMEOUT" "command_1=TIMEOUT exit=124 timeout=1"

echo "PASS: verify failures cannot produce PASS"
