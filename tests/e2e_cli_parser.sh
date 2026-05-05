#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
mkdir -p "$HOME/.codex" "$TMP_DIR/bin"
printf '{}\n' > "$HOME/.codex/auth.json"

export GIT_AUTHOR_NAME="Loop Test"
export GIT_AUTHOR_EMAIL="loop-test@example.com"
export GIT_COMMITTER_NAME="Loop Test"
export GIT_COMMITTER_EMAIL="loop-test@example.com"

PATH="$ROOT/tests/fake_cli:$PATH"
PATH="$TMP_DIR/bin:$PATH"
export PATH

cat > "$TMP_DIR/bin/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
chmod +x "$TMP_DIR/bin/envsubst"

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$FAKE_CLI_CALLS"
cat >/dev/null
cat <<'OUT'
# Fake Agent Output
VERDICT: PASS

## Goal
Parser smoke test

## Notes
none

- [x] Task 1: parser smoke complete
OUT
SH
chmod +x "$TMP_DIR/bin/codex"

export FAKE_CLI_CALLS="$TMP_DIR/fake_cli_calls.log"
: > "$FAKE_CLI_CALLS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "expected '$text' in $file"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    fail "did not expect '$text' in $file"
  fi
}

make_project() {
  local project="$TMP_DIR/$1"
  mkdir -p "$project/.loop-agent"
  printf '# Parser test project\n' > "$project/README.md"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1.1: Parser smoke task
  - Fail count: 0
MD
  echo "$project"
}

run_ok() {
  local name="$1"
  shift
  local out="$TMP_DIR/$name.out"
  if ! COMMIT_ON_PASS=0 "$ROOT/loop.sh" "$@" >"$out" 2>&1; then
    cat "$out" >&2
    fail "$name failed"
  fi
  echo "$out"
}

run_fail() {
  local name="$1"
  shift
  local out="$TMP_DIR/$name.out"
  if COMMIT_ON_PASS=0 "$ROOT/loop.sh" "$@" >"$out" 2>&1; then
    cat "$out" >&2
    fail "$name unexpectedly passed"
  fi
  echo "$out"
}

legacy_project="$(make_project legacy_project)"
legacy_out="$(run_ok legacy 5 "$legacy_project" codex)"
assert_contains "$legacy_out" "Loop Agent"
assert_contains "$legacy_out" "CLI:"

run_project="$(make_project run_project)"
run_out="$(run_ok explicit_run run --iterations 5 --project "$run_project" --cli codex)"
assert_contains "$run_out" "Loop Agent"
assert_contains "$run_out" "CLI:"
assert_not_contains "$run_out" "LOOP_MODE"
assert_not_contains "$run_out" "MAX_LOOPS"
assert_not_contains "$run_out" "PROJECT_DIR="

init_project="$(make_project init_project)"
init_out="$(run_ok explicit_init init --project "$init_project" --cli codex)"
assert_contains "$init_out" "Init mode parsed successfully."
assert_contains "$init_out" "CLI: codex"
assert_not_contains "$init_out" "Planner"
assert_not_contains "$init_out" "Implementer"

calls_before="$(wc -l < "$FAKE_CLI_CALLS" | tr -d ' ')"
missing_project_out="$(run_fail missing_project run --iterations 5 --cli codex)"
assert_contains "$missing_project_out" "Missing project."
invalid_subcommand_out="$(run_fail invalid_subcommand start --project "$init_project")"
assert_contains "$invalid_subcommand_out" "Invalid subcommand: start"
invalid_cli_out="$(run_fail invalid_cli run --iterations 5 --project "$init_project" --cli llama)"
assert_contains "$invalid_cli_out" "Invalid CLI value: llama"
invalid_iterations_out="$(run_fail invalid_iterations run --iterations 0 --project "$init_project" --cli codex)"
assert_contains "$invalid_iterations_out" "Iterations must be a positive integer: 0"
calls_after="$(wc -l < "$FAKE_CLI_CALLS" | tr -d ' ')"
[[ "$calls_before" == "$calls_after" ]] || fail "parser errors invoked codex"

echo "e2e_cli_parser.sh PASS"
