#!/usr/bin/env bash

create_temp_project() {
  local base="${TMPDIR:-/tmp}"
  local dir="$base/loop-agent-test-project-$$-$RANDOM"

  mkdir -p "$dir" || return 1
  git -C "$dir" init -q || return 1
  git -C "$dir" config user.name "Loop Agent Test" || return 1
  git -C "$dir" config user.email "loop-agent-test@example.com" || return 1

  printf '%s\n' "$dir"
}

create_temp_minimal_project() {
  local base="${TMPDIR:-/tmp}"
  local dir="$base/loop-agent-test-minimal-project-$$-$RANDOM"
  local script_dir
  local fixture_dir
  local candidate_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  fixture_dir=""
  for candidate_dir in "$script_dir"/../fixtures/*; do
    if [[ -f "$candidate_dir/.loop-agent/backlog.md" && -f "$candidate_dir/src/app.txt" ]]; then
      fixture_dir="$candidate_dir"
      break
    fi
  done

  [[ -d "$fixture_dir" ]] || return 1
  mkdir -p "$dir" || return 1
  cp -R "$fixture_dir"/. "$dir"/ || return 1

  git -C "$dir" init -q || return 1
  git -C "$dir" config user.name "Loop Agent Test" || return 1
  git -C "$dir" config user.email "loop-agent-test@example.com" || return 1
  git -C "$dir" add . || return 1
  git -C "$dir" commit -q -m "Initial fixture" || return 1

  printf '%s\n' "$dir"
}

create_temp_scope_expand_project() {
  local dir

  dir=$(create_temp_project) || return 1
  mkdir -p "$dir/.loop-agent" "$dir/src" || return 1
  printf '%s\n' "initial content" >"$dir/src/app.txt" || return 1
  cat >"$dir/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks

- [ ] Task 1: Complete fixture app update
  - Files: `src/app.txt`
  - What to do: Write deterministic happy-path content to the fixture app file.
  - Completion criteria:
    - [ ] `src/app.txt` contains `happy path complete`.
    - [ ] verify: `test "$(cat src/app.txt)" = "happy path complete"`
EOF

  git -C "$dir" add . || return 1
  git -C "$dir" commit -q -m "Initial scope expand fixture" || return 1

  printf '%s\n' "$dir"
}

create_temp_split_task_project() {
  local dir

  dir=$(create_temp_project) || return 1
  git -C "$dir" config core.autocrlf false || return 1
  mkdir -p "$dir/.loop-agent" "$dir/src" || return 1
  printf '%s\n' "split task initial content" >"$dir/src/app.txt" || return 1
  cat >"$dir/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks

- [ ] Task 1: Complete oversized fixture app update
  - Files: `src/app.txt`
  - What to do: Complete the fixture app update that should be split into smaller tasks.
  - Completion criteria:
    - [ ] `src/app.txt` contains `split task complete`.
    - [ ] verify: `grep -q "split task complete" src/app.txt`
EOF

  git -C "$dir" add . || return 1
  git -C "$dir" commit -q -m "Initial split task fixture" || return 1

  printf '%s\n' "$dir"
}

_project_factory_self_test() {
  local dir

  dir=$(create_temp_project) || return 1
  [[ -d "$dir" ]] || return 1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  rm -rf "$dir"
}

if [[ "${1:-}" == "--self-test" ]]; then
  _project_factory_self_test
fi
