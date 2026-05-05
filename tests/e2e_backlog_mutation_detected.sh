#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_fake_tools() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$bin_dir/envsubst"

  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null

count_file="${LOOP_FAKE_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

mutate_backlog() {
  local py_cmd=""
  if command -v python >/dev/null 2>&1 && [[ "$(command -v python)" != *"WindowsApps"* ]]; then
    py_cmd="python"
  elif command -v python3 >/dev/null 2>&1 && [[ "$(command -v python3)" != *"WindowsApps"* ]]; then
    py_cmd="python3"
  else
    echo "python not found" >&2
    exit 1
  fi

  "$py_cmd" - "$PWD/.loop-agent/backlog.md" "${LOOP_FAKE_MUTATION:?}" <<'PY'
import sys

path, mutation = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

if mutation == 'files':
    content = content.replace('  - Files: `demo.txt`', '  - Files: `demo.txt`, `extra.txt`')
elif mutation == 'verify':
    content = content.replace('    - [ ] verify: `test -f demo.txt`', '    - [ ] verify: `test -f demo.txt && test -f extra.txt`')
else:
    raise SystemExit('unknown mutation: ' + mutation)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PY
}

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Create demo file.
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
    mutate_backlog
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: demo

## Completion criteria status
- [x] verify: `test -f demo.txt`
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critic

## Notes
none

VERDICT: PASS
OUT
    ;;
  *)
    cat <<'OUT'
VERDICT: PASS
OUT
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

## Phase 1

- [ ] Task 1.1: Demo task
  - Description: Implement demo.
  - Files: `demo.txt`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] demo exists
    - [ ] verify: `test -f demo.txt`
MD
}

run_case() {
  local mutation="$1"
  local project="$TMP_ROOT/project-$mutation"
  local bin_dir="$TMP_ROOT/bin-$mutation"
  local home_dir="$TMP_ROOT/home-$mutation"
  local count_file="$TMP_ROOT/count-$mutation"
  local expected="$TMP_ROOT/expected-$mutation.md"
  local output="$TMP_ROOT/output-$mutation.txt"

  mkdir -p "$project" "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  write_fake_tools "$bin_dir"
  write_backlog "$project"
  cp "$project/.loop-agent/backlog.md" "$expected"

  set +e
  HOME="$home_dir" \
  PATH="$bin_dir:$PATH" \
  LOOP_FAKE_COUNT_FILE="$count_file" \
  LOOP_FAKE_MUTATION="$mutation" \
  GIT_AUTHOR_NAME="Loop Test" \
  GIT_AUTHOR_EMAIL="loop-test@example.invalid" \
  GIT_COMMITTER_NAME="Loop Test" \
  GIT_COMMITTER_EMAIL="loop-test@example.invalid" \
    bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" > "$output" 2>&1
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    cat "$output" >&2
    fail "$mutation mutation unexpectedly passed"
  fi

  if ! cmp -s "$project/.loop-agent/backlog.md" "$expected"; then
    cat "$project/.loop-agent/backlog.md" >&2
    fail "$mutation mutation was not restored"
  fi

  if [[ "$(cat "$count_file")" != "3" ]]; then
    cat "$output" >&2
    fail "$mutation mutation did not stop after Implementer"
  fi

  if ! grep -q "Backlog Semantic Mutation" "$project/.loop-agent/progress.txt"; then
    cat "$output" >&2
    cat "$project/.loop-agent/codex.log" >&2
    cat "$project/.loop-agent/progress.txt" >&2
    fail "$mutation mutation was not recorded in progress"
  fi

  if git -C "$project" log --format='%s' --grep='loop-agent: PASS' | grep -q .; then
    git -C "$project" log --oneline >&2
    fail "$mutation mutation created a PASS commit"
  fi
}

run_case files
run_case verify

echo "PASS: backlog semantic mutations are detected and restored"
