#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_SH="$ROOT_DIR/loop.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config core.autocrlf false
  printf 'base\n' > "$repo/base.txt"
  git -C "$repo" add base.txt
  git -C "$repo" commit -q -m "initial"
}

run_loop() {
  local repo="$1"
  local output="$2"
  shift 2
  env "$@" bash "$LOOP_SH" run --iterations 1 --project "$repo" > "$output" 2>&1
}

assert_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    echo "Output was:" >&2
    cat "$file" >&2
    fail "expected output to contain: $text"
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    echo "Output was:" >&2
    cat "$file" >&2
    fail "expected output not to contain: $text"
  fi
}

project_dirty_file_fails() {
  local repo="$TMP_ROOT/project-dirty-file"
  local output="$TMP_ROOT/project-dirty-file.out"
  init_repo "$repo"
  printf 'dirty\n' > "$repo/dirty.txt"

  if run_loop "$repo" "$output"; then
    fail "dirty project file was allowed without override"
  fi

  assert_contains "$output" "run mode requires a clean working tree"
  assert_contains "$output" "dirty.txt"
  assert_contains "$output" "Commit, stash, or revert"
  assert_contains "$output" "LOOP_ALLOW_DIRTY=1"
}

allowed_loop_agent_lifecycle_file_does_not_fail_preflight() {
  local repo="$TMP_ROOT/allowed-lifecycle-file"
  local output="$TMP_ROOT/allowed-lifecycle-file.out"
  init_repo "$repo"
  mkdir -p "$repo/.loop-agent"
  printf 'progress\n' > "$repo/.loop-agent/progress.txt"

  if run_loop "$repo" "$output"; then
    fail "run unexpectedly succeeded without backlog"
  fi

  assert_not_contains "$output" "run mode requires a clean working tree"
  assert_contains "$output" "run mode requires .loop-agent/backlog.md"
}

explicit_override_allows_dirty_project_file() {
  local repo="$TMP_ROOT/override"
  local output="$TMP_ROOT/override.out"
  init_repo "$repo"
  printf 'dirty\n' > "$repo/dirty.txt"

  if run_loop "$repo" "$output" LOOP_ALLOW_DIRTY=1; then
    fail "run unexpectedly succeeded without backlog"
  fi

  assert_contains "$output" "dirty tree protection is bypassed"
  assert_not_contains "$output" "run mode requires a clean working tree"
  assert_contains "$output" "run mode requires .loop-agent/backlog.md"
}

other_override_values_do_not_bypass() {
  local repo="$TMP_ROOT/override-disabled"
  local output="$TMP_ROOT/override-disabled.out"
  init_repo "$repo"
  printf 'dirty\n' > "$repo/dirty.txt"

  if run_loop "$repo" "$output" LOOP_ALLOW_DIRTY=true; then
    fail "dirty project file was allowed with non-1 override"
  fi

  assert_contains "$output" "run mode requires a clean working tree"
  assert_contains "$output" "dirty.txt"
}

project_dirty_file_fails
allowed_loop_agent_lifecycle_file_does_not_fail_preflight
explicit_override_allows_dirty_project_file
other_override_values_do_not_bypass

echo "PASS: clean-tree preflight e2e"
