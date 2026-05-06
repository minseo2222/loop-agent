#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_SH="$ROOT_DIR/loop.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "expected '$text' in $file"
}

python_cmd() {
  local path
  path="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$path" && "$path" != *"WindowsApps"* ]]; then
    printf 'python3\n'
    return
  fi
  path="$(command -v python 2>/dev/null || true)"
  if [[ -n "$path" && "$path" != *"WindowsApps"* ]]; then
    printf 'python\n'
    return
  fi
  fail "python not found"
}

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/envsubst" <<'FAKE_ENVSUBST'
#!/usr/bin/env bash
cat
FAKE_ENVSUBST

cat > "$FAKE_BIN/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null

count=0
if [[ -f "${FAKE_CODEX_COUNT_FILE:?}" ]]; then
  count="$(cat "$FAKE_CODEX_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT_FILE"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Run the scope comparison test.

## Tasks

### Task 1: Test task
- File: src/allowed.txt
- Completion criteria:
  - [ ] verify: `true`
OUT
    ;;
  2)
    cat <<'OUT'
VERDICT: PASS

## Notes
none
OUT
    ;;
  3)
    case "${SCOPE_SCENARIO:?}" in
      in_scope)
        printf 'changed\n' >> src/allowed.txt
        ;;
      out_of_scope)
        printf 'changed\n' >> README.md
        printf 'changed\n' >> docs/guide.md
        printf 'changed\n' >> tests/outside.test
        ;;
      empty)
        :
        ;;
      deleted)
        rm -f src/allowed.txt
        ;;
      *)
        echo "unknown scenario: $SCOPE_SCENARIO" >&2
        exit 2
        ;;
    esac
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Test task

## Completion criteria status
- [x] verify: `true`
OUT
    ;;
  4)
    cat <<'OUT'
VERDICT: PASS

## Notes
none
OUT
    ;;
  *)
    echo "unexpected codex call: $count" >&2
    exit 2
    ;;
esac
FAKE_CODEX

chmod +x "$FAKE_BIN/envsubst" "$FAKE_BIN/codex"

write_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'EOF_BACKLOG'
# Backlog

- [ ] Task 1.1: Scope comparison fixture
  - Description: Exercise scope comparison.
  - Files: `src/allowed.txt`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] Scope comparison is exercised.
    - [ ] verify: `true`
EOF_BACKLOG
}

assert_files_command_fails() {
  local name="$1"
  local body="$2"
  local backlog="$TMP_DIR/$name.md"
  local before output code py

  py="$(python_cmd)"
  printf '%s\n' "$body" > "$backlog"
  before="$(cat "$backlog")"

  set +e
  output="$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "$py" "$ROOT_DIR/backlog_manager.py" files "$backlog" "Task 1.1" 2>&1)"
  code=$?
  set -e

  [[ "$code" -ne 0 ]] || fail "files command should fail for $name"
  [[ "$output" == ERROR:* ]] || fail "files command did not fail explicitly for $name: $output"
  [[ "$(cat "$backlog")" == "$before" ]] || fail "files command modified backlog for $name"
}

prepare_project() {
  local scenario="$1"
  local project="$TMP_DIR/project-$scenario"

  mkdir -p "$project/src" "$project/docs" "$project/tests"
  printf '.loop-agent/\n' > "$project/.gitignore"
  printf 'base\n' > "$project/src/allowed.txt"
  printf 'readme\n' > "$project/README.md"
  printf 'docs\n' > "$project/docs/guide.md"
  printf 'test\n' > "$project/tests/outside.test"
  write_backlog "$project"

  git -C "$project" init -q
  git -C "$project" config user.email scope-test@example.com
  git -C "$project" config user.name "Scope Test"
  git -C "$project" config core.autocrlf false
  git -C "$project" add -A
  git -C "$project" commit -q -m initial

  printf '%s\n' "$project"
}

run_scenario() {
  local scenario="$1"
  local expected="$2"
  local project home count_file out_file err_file evidence

  project="$(prepare_project "$scenario")"
  home="$TMP_DIR/home-$scenario"
  count_file="$TMP_DIR/count-$scenario.txt"
  out_file="$TMP_DIR/$scenario.out"
  err_file="$TMP_DIR/$scenario.err"
  mkdir -p "$home/.codex"
  printf '{}\n' > "$home/.codex/auth.json"

  set +e
  PATH="$FAKE_BIN:$PATH" \
    HOME="$home" \
    FAKE_CODEX_COUNT_FILE="$count_file" \
    SCOPE_SCENARIO="$scenario" \
    COMMIT_ON_PASS=0 \
    bash "$LOOP_SH" run --iterations 1 --project "$project" --cli codex \
    > "$out_file" 2> "$err_file"
  code=$?
  set -e

  if [[ "$expected" == "pass" && "$code" -ne 0 ]]; then
    cat "$out_file" >&2 || true
    cat "$err_file" >&2 || true
    fail "$scenario should pass"
  fi
  if [[ "$expected" == "fail" && "$code" -eq 0 ]]; then
    cat "$out_file" >&2 || true
    cat "$err_file" >&2 || true
    fail "$scenario should fail"
  fi

  evidence="$project/.loop-agent/evidence/loop-1"
  assert_file "$evidence/allowed_files.txt"
  assert_file "$evidence/scope_check.txt"
  assert_file "$evidence/out_of_scope.txt"
  assert_contains "$evidence/allowed_files.txt" "src/allowed.txt"

  case "$scenario" in
    in_scope)
      assert_contains "$evidence/scope_check.txt" "RESULT: PASS"
      ;;
    out_of_scope)
      assert_contains "$evidence/scope_check.txt" "RESULT: FAIL"
      assert_contains "$evidence/out_of_scope.txt" "README.md"
      assert_contains "$evidence/out_of_scope.txt" "docs/guide.md"
      assert_contains "$evidence/out_of_scope.txt" "tests/outside.test"
      ;;
    empty)
      assert_contains "$evidence/scope_check.txt" "RESULT: NO_CHANGES"
      ;;
    deleted)
      assert_contains "$evidence/scope_check.txt" "RESULT: PASS"
      assert_contains "$evidence/changed_files.txt" "src/allowed.txt"
      ;;
  esac
}

assert_files_command_fails "missing-files" "# Backlog

- [ ] Task 1.1: Missing files fixture
  - Description: Missing Files should fail.
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] verify: \`true\`"

assert_files_command_fails "invalid-files" "# Backlog

- [ ] Task 1.1: Invalid files fixture
  - Description: Invalid Files should fail.
  - Files: \`/tmp/outside.txt\`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] verify: \`true\`"

run_scenario in_scope pass
run_scenario out_of_scope fail
run_scenario empty pass
run_scenario deleted pass

echo "e2e_scope_comparison: PASS"
