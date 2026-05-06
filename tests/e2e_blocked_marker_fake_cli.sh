#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

project_dir="$tmp_dir/project"
backlog_file="$project_dir/.loop-agent/backlog.md"
mkdir -p "$project_dir/.loop-agent"

cat > "$backlog_file" <<'BACKLOG'
# Test Backlog

## Phase 13

- [ ] Task 13.1: Complete marker fixture
  - Files: `tests/e2e_blocked_marker_fake_cli.sh`
  - Depends: none
  - Fail count: 0
  - Verify: `bash tests/e2e_blocked_marker_fake_cli.sh`
  - Completion criteria:
    - [ ] The script is self-contained and does not modify repo `.loop-agent/` files.
    - [ ] The test checks exact marker text in `.loop-agent/backlog.md`.

- [ ] Task 13.2: Block marker fixture
  - Files: `tests/e2e_blocked_marker_fake_cli.sh`
  - Depends: Task 13.1
  - Fail count: 0
  - Verify: `bash tests/e2e_blocked_marker_fake_cli.sh`
  - Completion criteria:
    - [ ] The block command emits the exact blocked marker.

- [ ] Task 13.3: Fail-to-block marker fixture
  - Files: `tests/e2e_blocked_marker_fake_cli.sh`
  - Depends: Task 13.2
  - Fail count: 0
  - Verify: `bash tests/e2e_blocked_marker_fake_cli.sh`
  - Completion criteria:
    - [ ] The fail command emits the exact blocked marker at max attempts.
BACKLOG

show_backlog() {
  echo "Updated backlog:"
  cat "$backlog_file"
}

assert_marker() {
  local expected="$1"
  if ! grep -F -- "$expected" "$backlog_file" >/dev/null; then
    echo "Expected marker was not found: $expected" >&2
    show_backlog >&2
    exit 1
  fi
}

assert_no_malformed_marker() {
  if grep -F -- "[!\\]" "$backlog_file" >/dev/null; then
    echo "Malformed blocked marker was found." >&2
    show_backlog >&2
    exit 1
  fi
}

assert_marker "- [ ] Task 13.1:"
assert_marker "- [ ] Task 13.2:"
assert_marker "- [ ] Task 13.3:"
assert_no_malformed_marker

python "$repo_root/backlog_manager.py" complete \
  "$backlog_file" \
  "Task 13.1" >/dev/null

assert_marker "- [x] Task 13.1:"
assert_no_malformed_marker

python "$repo_root/backlog_manager.py" block \
  "$backlog_file" \
  "Task 13.2" \
  "Regression fixture" \
  "FAIL" \
  ".loop-agent/evidence/loop-1/" >/dev/null

assert_marker "- [!] Task 13.2:"
assert_no_malformed_marker

python "$repo_root/backlog_manager.py" fail \
  "$backlog_file" \
  "Task 13.3" \
  "1" \
  "Regression fixture" \
  ".loop-agent/evidence/loop-1/" >/dev/null

assert_marker "- [!] Task 13.3:"
assert_no_malformed_marker

malformed_backlog="$tmp_dir/malformed.md"
cat > "$malformed_backlog" <<'BACKLOG'
# Malformed Backlog

## Phase 13

- [!\] Task 13.4: Malformed blocked marker
  - Files: `tests/e2e_blocked_marker_fake_cli.sh`
  - Depends: none
  - Fail count: 0
  - Verify: `bash tests/e2e_blocked_marker_fake_cli.sh`
  - Completion criteria:
    - [ ] Lint rejects malformed task markers.
BACKLOG

lint_output="$tmp_dir/lint_output.txt"
if python "$repo_root/backlog_manager.py" lint "$malformed_backlog" >"$lint_output" 2>&1; then
  echo "Lint accepted a malformed blocked marker." >&2
  cat "$lint_output" >&2
  exit 1
fi

expected_lint_error="line 5: malformed task marker [!\\]; use [!]"
if ! grep -F -- "$expected_lint_error" "$lint_output" >/dev/null; then
  echo "Lint did not report the malformed blocked marker." >&2
  cat "$lint_output" >&2
  exit 1
fi

echo "PASS"
