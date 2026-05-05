#!/usr/bin/env bash
set -u

fail() {
  echo "e2e_pass_fake_cli: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
PATH="$repo_root/tests/fake_cli:$PATH"
export PATH

fake_codex="$(command -v codex)" || fail "codex not found"
[[ "$fake_codex" == "$repo_root/tests/fake_cli/codex" ]] || fail "fake codex is not first in PATH"
codex --self-test >/dev/null || fail "fake codex self-test failed"

source "$repo_root/tests/lib/project_factory.sh"

project_dir="$(create_temp_minimal_project)" || fail "failed to create minimal project"
trap 'rm -rf "$project_dir"' EXIT

backlog="$project_dir/.loop-agent/backlog.md"
[[ -f "$backlog" ]] || fail "fixture backlog missing"
if ! grep -q 'verify:' "$backlog"; then
  printf '.loop-agent/\n' > "$project_dir/.gitignore" || fail "failed to add fixture gitignore"
  tmp_backlog="$project_dir/.loop-agent/backlog.with-verify.md"
  awk '
    {
      print
      if (!added && $0 ~ /^- \[ \] Task 1\.1:/) {
        print "  Completion criteria:"
        print "  - [ ] verify: `grep -Fqx \"happy path complete\" src/app.txt`"
        added = 1
      }
    }
  ' "$backlog" > "$tmp_backlog" || fail "failed to add fixture verify command"
  mv "$tmp_backlog" "$backlog" || fail "failed to update fixture backlog"
  git -C "$project_dir" add .gitignore || fail "failed to stage fixture gitignore"
  git -C "$project_dir" add -f .loop-agent/backlog.md || fail "failed to stage fixture verify command"
  git -C "$project_dir" commit --amend --no-edit -q || fail "failed to commit fixture verify command"
  git -C "$project_dir" reset --hard -q || fail "failed to reset fixture after verify command"
fi
fixture_task_line="$(grep -m1 '^- \[ \] ' "$backlog")" || fail "fixture task line missing"
completed_task_line="${fixture_task_line/- \[ \]/- [x]}"

initial_commits="$(git -C "$project_dir" rev-list --count HEAD)" || fail "failed to count initial commits"
[[ "$initial_commits" -eq 1 ]] || fail "expected exactly one initial commit, got $initial_commits"

set +e
(
  cd "$repo_root" || exit 1
  export LOOP_FAKE_PROJECT_DIR="$project_dir"
  export LOOP_FAKE_SCENARIO=pass
  ./loop.sh 1 "$project_dir" codex
)
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "loop exited with $status"

task_complete=0
if [[ -f "$project_dir/.loop-agent/backlog.md" ]] && grep -Fqx -- "$completed_task_line" "$project_dir/.loop-agent/backlog.md"; then
  task_complete=1
fi
if [[ -f "$project_dir/.loop-agent/backlog_archive.md" ]] && grep -Fqx -- "$completed_task_line" "$project_dir/.loop-agent/backlog_archive.md"; then
  task_complete=1
fi
[[ "$task_complete" -eq 1 ]] || fail "specific fixture task was not marked complete"
[[ "$(cat "$project_dir/src/app.txt")" == "happy path complete" ]] || fail "fixture source was not updated"

final_commits="$(git -C "$project_dir" rev-list --count HEAD)" || fail "failed to count final commits"
[[ "$final_commits" -gt "$initial_commits" ]] || fail "expected loop to create at least one commit"

[[ -e "$project_dir/.loop-agent/progress.txt" || -e "$project_dir/.loop-agent/report.md" ]] || fail "missing progress or report output"
