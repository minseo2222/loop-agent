#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_DIR/lib/decision.sh"

assert_verdict() {
  local name="$1"
  local expected="$2"
  local content="$3"
  local file="$TMP_DIR/$name.txt"
  local actual

  printf "%b" "$content" > "$file"
  actual="$(check_verdict "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $name: expected $expected, got $actual" >&2
    echo "Content:" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_verdict "pass" "PASS" "Notes before verdict\nVERDICT: PASS\n"
assert_verdict "fail" "FAIL" "VERDICT: FAIL\n"
assert_verdict "blocked" "BLOCKED" "VERDICT: BLOCKED\n"
assert_verdict "scope_expand" "SCOPE_EXPAND" "VERDICT: SCOPE_EXPAND\n"
assert_verdict "split_task" "SPLIT_TASK" "VERDICT: SPLIT_TASK\n"
assert_verdict "body_pass" "UNKNOWN" "This body says PASS but has no verdict line.\n"
assert_verdict "duplicate" "MALFORMED" "VERDICT: PASS\nVERDICT: FAIL\n"
assert_verdict "malformed" "MALFORMED" "VERDICT: PASS extra\n"
assert_verdict "trailing_text" "MALFORMED" "VERDICT: PASS\nTrailing text\n"

assert_true() {
  local name="$1"
  shift

  if ! "$@"; then
    echo "FAIL $name: expected success" >&2
    exit 1
  fi
}

assert_false() {
  local name="$1"
  shift

  if "$@"; then
    echo "FAIL $name: expected failure" >&2
    exit 1
  fi
}

assert_block_reason() {
  local name="$1"
  local expected="$2"
  local default_reason="$3"
  local content="$4"
  local file="$TMP_DIR/$name.txt"
  local actual

  printf "%b" "$content" > "$file"
  actual="$(decision_extract_block_reason "$file" "$default_reason")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $name: expected $expected, got $actual" >&2
    exit 1
  fi
}

assert_true "invalid_unknown" decision_is_invalid_verdict "UNKNOWN"
assert_true "invalid_malformed" decision_is_invalid_verdict "MALFORMED"
assert_false "invalid_pass" decision_is_invalid_verdict "PASS"

assert_true "proposal_scope_expand" decision_is_proposal_verdict "SCOPE_EXPAND"
assert_true "proposal_split_task" decision_is_proposal_verdict "SPLIT_TASK"
assert_true "proposal_dependency_insert" decision_is_proposal_verdict "DEPENDENCY_INSERT"
assert_false "proposal_blocked" decision_is_proposal_verdict "BLOCKED"

assert_block_reason "block_notes" "Needs a missing dependency." "Default reason." "## Notes\n- Needs a missing dependency.\n\nVERDICT: BLOCKED\n"
assert_block_reason "block_fallback" "First plain reason." "Default reason." "# Title\n\nFirst plain reason.\nVERDICT: BLOCKED\n"
assert_block_reason "block_default" "Default reason." "Default reason." "# Title\n\nVERDICT: BLOCKED\n"

echo "e2e_verdict_parser: PASS"
