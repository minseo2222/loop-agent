#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/loop-agent-proposal-verdict-$$"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python_cmd() {
  local candidate
  candidate="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != *"WindowsApps"* ]]; then
    echo python3
    return
  fi
  candidate="$(command -v python 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != *"WindowsApps"* ]]; then
    echo python
    return
  fi
  fail "python is required"
}

make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

count_file="${FAKE_CODEX_COUNT_FILE:?}"
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

## Goal
Exercise proposal verdict handling.
OUT
    ;;
  2)
    cat <<'OUT'
# Plan Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
  3)
    printf 'created by fake implementer\n' > created_by_impl.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Fake implementation

## Completion criteria status
- [x] verify: `true`
OUT
    ;;
  4)
    case "${FAKE_IMPL_VERDICT:?}" in
      SCOPE_EXPAND)
        cat <<'OUT'
# Impl Critique

## Scope expansion needed
- `requested_extra.txt` - Needed for the reviewed change.

VERDICT: SCOPE_EXPAND
OUT
        ;;
      SPLIT_TASK)
        cat <<'OUT'
# Impl Critique

## Split task
- Create one smaller task for setup.
- Create one smaller task for verification.

VERDICT: SPLIT_TASK
OUT
        ;;
      *)
        echo "unknown FAKE_IMPL_VERDICT" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unexpected fake codex call $count" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$bin_dir/codex"
}

write_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

## Tasks

- [ ] Task 1.1: Proposal verdict case
  - Files:
    - `created_by_impl.txt`
  - Depends: none
  - Completion criteria:
    - Proposal verdict is handled.
    - verify: `true`
  - Fail count: 0
BACKLOG
}

run_case() {
  local verdict="$1"
  local case_dir="$TMP_ROOT/$verdict"
  local project="$case_dir/project"
  local fake_bin="$case_dir/bin"
  local fake_home="$case_dir/home"
  local output="$case_dir/loop.out"
  local py
  local before_head
  local before_semantics
  local after_semantics
  local status_json
  local proposal_glob
  local proposal_count
  local task_count
  local exit_code

  py="$(python_cmd)"
  mkdir -p "$project" "$fake_home/.codex"
  printf '{}\n' > "$fake_home/.codex/auth.json"
  make_fake_codex "$fake_bin"
  write_backlog "$project"
  printf 'baseline\n' > "$project/baseline.txt"
  printf '# loop-agent state files (no git tracking needed)\n.loop-agent/\n' > "$project/.gitignore"
  git -C "$project" init -q
  git -C "$project" config core.autocrlf false
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" add baseline.txt .gitignore
  git -C "$project" commit -q -m "baseline"

  "$py" "$ROOT/backlog_manager.py" lint "$project/.loop-agent/backlog.md" >/dev/null
  before_head="$(git -C "$project" rev-parse HEAD)"
  before_semantics="$(grep -E 'Files:|Depends:|Completion criteria:|`created_by_impl.txt`|verify: `true`|Proposal verdict is handled' "$project/.loop-agent/backlog.md")"

  set +e
  HOME="$fake_home" PATH="$fake_bin:$PATH" FAKE_IMPL_VERDICT="$verdict" FAKE_CODEX_COUNT_FILE="$case_dir/codex_count" \
    bash "$ROOT/loop.sh" run --iterations 1 --project "$project" > "$output" 2>&1
  exit_code=$?
  set -e
  [[ "$exit_code" -eq 1 ]] || fail "$verdict loop exit code was $exit_code; expected 1. Output: $(tail -40 "$output")"

  [[ ! -e "$project/created_by_impl.txt" ]] || fail "$verdict left implementation-created file after rollback"
  [[ "$(git -C "$project" rev-parse HEAD)" == "$before_head" ]] || fail "$verdict created a git commit: $(git -C "$project" log --oneline -3) files: $(git -C "$project" show --name-only --format= HEAD | tr '\n' ' ')"

  proposal_glob="$project/.loop-agent/proposals"
  proposal_count="$(find "$proposal_glob" -type f -name "*$(printf '%s' "$verdict" | tr '[:upper:]' '[:lower:]')*" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$proposal_count" -ge 1 ]] || fail "$verdict did not write a proposal file"
  [[ -f "$project/.loop-agent/evidence/loop-1/proposal_verdict.md" ]] || fail "$verdict proposal evidence is missing"
  [[ -f "$project/.loop-agent/evidence/loop-1/changed_files_after_implementer.txt" ]] || fail "$verdict changed-file evidence is missing"

  status_json="$("$py" "$ROOT/backlog_manager.py" status "$project/.loop-agent/backlog.md")"
  printf '%s\n' "$status_json" | grep -Eq '"blocked"[[:space:]]*:[[:space:]]*1' || fail "$verdict did not block the current task"
  grep -Fq "$verdict" "$project/.loop-agent/backlog.md" || fail "$verdict block metadata did not record the verdict"
  grep -Fq ".loop-agent/evidence/loop-1/" "$project/.loop-agent/backlog.md" || fail "$verdict block metadata did not record evidence path"

  after_semantics="$(grep -E 'Files:|Depends:|Completion criteria:|`created_by_impl.txt`|verify: `true`|Proposal verdict is handled' "$project/.loop-agent/backlog.md")"
  [[ "$after_semantics" == "$before_semantics" ]] || fail "$verdict changed backlog semantic fields"

  grep -Fq 'requested_extra.txt' "$project/.loop-agent/proposals"/* 2>/dev/null || [[ "$verdict" != "SCOPE_EXPAND" ]] || fail "SCOPE_EXPAND proposal omitted requested file"
  grep -Fq 'requested_extra.txt' "$project/.loop-agent/backlog.md" && fail "SCOPE_EXPAND mutated Files instead of proposal-only blocking"

  task_count="$(grep -Ec '^- \[[^]]+\] Task ' "$project/.loop-agent/backlog.md")"
  [[ "$task_count" -eq 1 ]] || fail "SPLIT_TASK created child tasks"
}

mkdir -p "$TMP_ROOT"
run_case SCOPE_EXPAND
run_case SPLIT_TASK

echo "PASS: proposal verdict handlers"
