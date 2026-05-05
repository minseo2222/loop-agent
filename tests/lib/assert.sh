#!/usr/bin/env bash

_assert_fail() {
  printf 'Assertion failed: %s\n' "$*" >&2
  return 1
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || _assert_fail "expected file to exist: $path"
}

assert_file_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || _assert_fail "expected path not to exist: $path"
}

assert_contains() {
  local path="$1"
  local expected="$2"
  local content

  [[ -f "$path" ]] || _assert_fail "expected file to exist: $path"
  content=$(<"$path")
  [[ "$content" == *"$expected"* ]] || _assert_fail "expected $path to contain: $expected"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  local content

  [[ -f "$path" ]] || _assert_fail "expected file to exist: $path"
  content=$(<"$path")
  [[ "$content" != *"$unexpected"* ]] || _assert_fail "expected $path not to contain: $unexpected"
}

assert_success() {
  "$@" || _assert_fail "expected command to succeed: $*"
}

assert_failure() {
  if "$@"; then
    _assert_fail "expected command to fail: $*"
  fi
}

_assert_self_test() {
  local dir="${TMPDIR:-/tmp}/assert-self-test-$$"
  local file="$dir/sample.txt"

  rm -rf "$dir"
  mkdir -p "$dir"
  printf 'alpha\nbeta\n' > "$file"

  assert_file_exists "$file"
  assert_file_not_exists "$dir/missing.txt"
  assert_contains "$file" "alpha"
  assert_not_contains "$file" "gamma"
  assert_success true
  assert_failure false

  rm -rf "$dir"
}

if [[ "${1:-}" == "--self-test" ]]; then
  _assert_self_test
fi
