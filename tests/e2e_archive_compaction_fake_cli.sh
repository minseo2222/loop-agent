#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BACKLOG="$WORK_DIR/backlog.md"
ARCHIVE="$WORK_DIR/backlog_archive.md"

cat > "$BACKLOG" <<'EOF'
# Backlog

## Completed Task IDs

- Task 0.1

## Phase 1

## Tasks

- [x] Task 1.1: Completed alpha
  - Files: `alpha.txt`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [x] Alpha is complete.

## Tasks

## Phase 2

Shared active phase context.

## Tasks

- [x] Task 2.1: Completed beta
  - Files: `beta.txt`
  - Depends: Task 1.1
  - Fail count: 0
  - Completion criteria:
    - [x] Beta is complete.

- [ ] Task 2.2: Active gamma
  - Files: `gamma.txt`
  - Depends: Task 2.1
  - Fail count: 0
  - Verify: `echo active`
  - Completion criteria:
    - [ ] Gamma remains active.

## Tasks

## Phase 3

## Tasks

- [x] Task 3.1: Completed delta
  - Files: `delta.txt`
  - Depends: Task 2.2
  - Fail count: 0
  - Completion criteria:
    - [x] Delta is complete.

## Tasks
EOF

python "$REPO_ROOT/backlog_manager.py" compact "$BACKLOG" "$ARCHIVE" >/dev/null

require_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Expected $file to contain: $text" >&2
    exit 1
  fi
}

require_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    echo "Expected $file not to contain: $text" >&2
    exit 1
  fi
}

require_contains "$ARCHIVE" "- [x] Task 1.1: Completed alpha"
require_contains "$ARCHIVE" "- [x] Task 2.1: Completed beta"
require_contains "$ARCHIVE" "- [x] Task 3.1: Completed delta"
require_contains "$ARCHIVE" "Alpha is complete."
require_contains "$ARCHIVE" "Beta is complete."
require_contains "$ARCHIVE" "Delta is complete."
require_not_contains "$ARCHIVE" "- [ ] Task 2.2: Active gamma"

require_contains "$BACKLOG" "- Task 0.1"
require_contains "$BACKLOG" "- Task 1.1"
require_contains "$BACKLOG" "- Task 2.1"
require_contains "$BACKLOG" "- Task 3.1"
require_contains "$BACKLOG" "## Phase 2"
require_contains "$BACKLOG" "Shared active phase context."
require_contains "$BACKLOG" "- [ ] Task 2.2: Active gamma"
require_contains "$BACKLOG" "Gamma remains active."

require_not_contains "$BACKLOG" "- [x] Task 1.1: Completed alpha"
require_not_contains "$BACKLOG" "- [x] Task 2.1: Completed beta"
require_not_contains "$BACKLOG" "- [x] Task 3.1: Completed delta"
require_not_contains "$BACKLOG" "## Phase 1"
require_not_contains "$BACKLOG" "## Phase 3"

tasks_heading_count="$(grep -c '^## Tasks$' "$BACKLOG" || true)"
if [ "$tasks_heading_count" -ne 1 ]; then
  echo "Expected compacted backlog to contain exactly one ## Tasks heading, found $tasks_heading_count" >&2
  exit 1
fi

lint_output="$WORK_DIR/lint_output.txt"
python "$REPO_ROOT/backlog_manager.py" lint "$BACKLOG" >"$lint_output" 2>&1
require_contains "$lint_output" "LINT OK: 1 tasks checked"

MALFORMED_BACKLOG="$WORK_DIR/repeated_empty_tasks.md"
cat > "$MALFORMED_BACKLOG" <<'EOF'
# Backlog

## Completed Task IDs

- Task 1.1

## Phase 1

## Tasks

## Phase 2

## Tasks
EOF

if python "$REPO_ROOT/backlog_manager.py" lint "$MALFORMED_BACKLOG" >"$lint_output" 2>&1; then
  echo "Lint accepted repeated empty ## Tasks sections." >&2
  cat "$lint_output" >&2
  exit 1
fi

require_contains "$lint_output" "line 13: empty repeated ## Tasks section; run backlog compaction cleanup"
