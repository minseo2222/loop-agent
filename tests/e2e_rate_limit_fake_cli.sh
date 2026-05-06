#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$project_dir"
}
trap cleanup EXIT

mkdir -p "$project_dir/.loop-agent" "$project_dir/src"

cat >"$project_dir/.loop-agent/backlog.md" <<'EOF'
# Backlog

- [ ] Task 1.1: Complete fixture app update
  - Fail count: 0
  - File: `src/app.txt`
  - What to do: Write deterministic happy-path content to the fixture app file.
  - Completion criteria:
    - [ ] `src/app.txt` contains `happy path complete`.
    - [ ] verify: `test "$(cat src/app.txt)" = "happy path complete"`
EOF

cat >"$project_dir/src/app.txt" <<'EOF'
initial
EOF

cat >"$project_dir/.gitignore" <<'EOF'
.loop-agent/
EOF

(
  cd "$project_dir"
  git init -q
  git config user.email "loop-test@example.com"
  git config user.name "Loop Test"
  git add .gitignore src/app.txt
  git add -f .loop-agent/backlog.md
  git commit -q -m "Initial fixture"
)

backlog_file="$project_dir/.loop-agent/backlog.md"
status_before="$(grep -E '^- \[[ x]\] Task 1\.1:' "$backlog_file")"
fail_count_before="$(grep -E 'Fail count:' "$backlog_file" | sed -E 's/.*Fail count: *([0-9]+).*/\1/')"
commit_count_before="$(git -C "$project_dir" rev-list --count HEAD)"

set +e
(
  cd "$repo_root"
  PATH="$repo_root/tests/fake_cli:$PATH" \
    LOOP_FAKE_SCENARIO=rate_limit \
    LOOP_FAKE_PROJECT_DIR="$project_dir" \
    bash ./loop.sh 1 "$project_dir" codex
)
exit_code=$?
set -e

if [ "$exit_code" -ne 2 ]; then
  echo "expected exit code 2, got $exit_code" >&2
  exit 1
fi

status_after="$(grep -E '^- \[[ x]\] Task 1\.1:' "$backlog_file")"
fail_count_after="$(grep -E 'Fail count:' "$backlog_file" | sed -E 's/.*Fail count: *([0-9]+).*/\1/')"
commit_count_after="$(git -C "$project_dir" rev-list --count HEAD)"
git_status_after="$(git -C "$project_dir" status --short)"

if [ "$status_after" != "$status_before" ]; then
  echo "expected task status to remain unchanged" >&2
  echo "before: $status_before" >&2
  echo "after:  $status_after" >&2
  exit 1
fi

case "$status_after" in
  "- [ ] Task 1.1:"*) ;;
  *)
    echo "expected task to remain pending, got: $status_after" >&2
    exit 1
    ;;
esac

if [ "$fail_count_after" != "$fail_count_before" ]; then
  echo "expected fail count to remain $fail_count_before, got $fail_count_after" >&2
  exit 1
fi

if [ "$commit_count_after" != "$commit_count_before" ]; then
  echo "expected commit count to remain $commit_count_before, got $commit_count_after" >&2
  exit 1
fi

if [ -n "$git_status_after" ]; then
  echo "expected clean working tree, got:" >&2
  echo "$git_status_after" >&2
  git -C "$project_dir" diff -- .gitignore >&2
  exit 1
fi

echo "rate-limit fake CLI E2E passed"
