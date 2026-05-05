#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
if [[ "${KEEP_LOOP_TEST_TMP:-0}" != "1" ]]; then
  trap 'rm -rf "$TMP_ROOT"' EXIT
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

count_file="${FAKE_CODEX_COUNT_FILE:?}"
scope_paths="${FAKE_SCOPE_EXPAND_PATHS:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Tasks
- Task 1
OUT
    ;;
  2)
    cat <<'OUT'
# Plan Review

## Notes
none

VERDICT: PASS
OUT
    ;;
  3)
    cat <<'OUT'
# Implementation Summary

## Tasks completed
None.
OUT
    ;;
  *)
    echo "# Impl Critic"
    echo
    echo "## Scope expansion needed"
    IFS=';' read -ra paths <<< "$scope_paths"
    for path in "${paths[@]}"; do
      [[ -n "$path" ]] && echo "- \`$path\`"
    done
    echo
    echo "VERDICT: SCOPE_EXPAND"
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

write_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1: Scope test
  - Files: existing.txt
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] scope expansion handled
  - verify: true
MD
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  printf 'existing\n' > "$project/existing.txt"
  printf '.loop-agent/\n' > "$project/.gitignore"
  write_backlog "$project"
  git -C "$project" init -q
  git -C "$project" config core.autocrlf false
  git -C "$project" config user.email "loop-test@example.com"
  git -C "$project" config user.name "Loop Test"
  git -C "$project" add .
  git -C "$project" commit -q -m "initial"
}

run_loop_case() {
  local name="$1"
  local allow_flag="$2"
  local requested_paths="$3"
  local project="$TMP_ROOT/$name/project"
  local fake_bin="$TMP_ROOT/$name/bin"
  local fake_home="$TMP_ROOT/$name/home"
  local count_file="$TMP_ROOT/$name/count"
  local output_file="$TMP_ROOT/$name/output.txt"
  local status

  mkdir -p "$TMP_ROOT/$name" "$fake_home/.codex"
  printf '{}\n' > "$fake_home/.codex/auth.json"
  make_project "$project"
  make_fake_codex "$fake_bin"

  set +e
  if [[ "$allow_flag" == "1" ]]; then
    PATH="$fake_bin:$PATH" HOME="$fake_home" FAKE_CODEX_COUNT_FILE="$count_file" FAKE_SCOPE_EXPAND_PATHS="$requested_paths" LOOP_ALLOW_DIRTY=1 LOOP_ALLOW_AUTO_SCOPE_EXPAND=1 COMMIT_ON_PASS=0 bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" > "$output_file" 2>&1
  else
    PATH="$fake_bin:$PATH" HOME="$fake_home" FAKE_CODEX_COUNT_FILE="$count_file" FAKE_SCOPE_EXPAND_PATHS="$requested_paths" LOOP_ALLOW_DIRTY=1 COMMIT_ON_PASS=0 bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" > "$output_file" 2>&1
  fi
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    cat "$output_file" >&2
    fail "$name exited with unexpected status $status"
  fi

  printf '%s\n' "$project"
}

default_project="$(run_loop_case default 0 "extra.txt")"
grep -q '  - Files: existing.txt$' "$default_project/.loop-agent/backlog.md" || fail "default mode changed Files"
grep -q '"event":"mutation".*"outcome":"attempted"' "$default_project/.loop-agent/events.jsonl" || fail "default mode did not log attempted mutation"
grep -q '"event":"mutation".*"outcome":"rejected"' "$default_project/.loop-agent/events.jsonl" || fail "default mode did not log rejected mutation"

valid_project="$(run_loop_case valid 1 "extra.txt")"
grep -q '  - Files: existing.txt, extra.txt$' "$valid_project/.loop-agent/backlog.md" || fail "flagged valid expansion did not update Files"
grep -q '"event":"mutation".*"outcome":"accepted"' "$valid_project/.loop-agent/events.jsonl" || fail "flagged valid expansion did not log accepted mutation"
grep -q 'LINT OK' "$valid_project/.loop-agent/evidence/loop-1/scope_expand_mutation.md" || fail "flagged valid expansion did not record lint output"

absolute_project="$(run_loop_case absolute 1 "/tmp/secret.txt")"
grep -q '  - Files: existing.txt$' "$absolute_project/.loop-agent/backlog.md" || fail "absolute path changed Files"
grep -q 'absolute path' "$absolute_project/.loop-agent/evidence/loop-1/scope_expand_mutation.md" || fail "absolute path rejection evidence missing"
grep -q '"event":"mutation".*"outcome":"rejected"' "$absolute_project/.loop-agent/events.jsonl" || fail "absolute path rejection event missing"

parent_project="$(run_loop_case parent 1 "../outside.txt")"
grep -q '  - Files: existing.txt$' "$parent_project/.loop-agent/backlog.md" || fail "parent traversal changed Files"
grep -q 'parent traversal' "$parent_project/.loop-agent/evidence/loop-1/scope_expand_mutation.md" || fail "parent traversal rejection evidence missing"

over_project="$(run_loop_case overlimit 1 "a.txt;b.txt;c.txt;d.txt")"
grep -q '  - Files: existing.txt$' "$over_project/.loop-agent/backlog.md" || fail "over-limit expansion changed Files"
grep -q 'max 3 added files exceeded' "$over_project/.loop-agent/evidence/loop-1/scope_expand_mutation.md" || fail "over-limit rejection evidence missing"
grep -q '"event":"mutation".*"outcome":"rejected"' "$over_project/.loop-agent/events.jsonl" || fail "over-limit rejection event missing"

echo "e2e_experimental_scope_expand_flag: PASS"
