#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_repo() {
  local repo="$1"
  local branch="$2"

  mkdir -p "$repo"
  git -c init.defaultBranch=baseline init -q "$repo"
  git -C "$repo" checkout -q -b "$branch"
}

run_loop() {
  local repo="$1"
  local output="$2"
  shift 2

  set +e
  (
    cd "$ROOT_DIR"
    "$@" ./loop.sh run --project "$repo" --iterations 1 --cli codex
  ) > "$output" 2>&1
  local status=$?
  set -e
  return "$status"
}

assert_contains() {
  local file="$1"
  local text="$2"

  if ! grep -Fq "$text" "$file"; then
    echo "Expected output to contain: $text" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"

  if grep -Fq "$text" "$file"; then
    echo "Expected output not to contain: $text" >&2
    cat "$file" >&2
    exit 1
  fi
}

FAKE_BIN="$TMP_DIR/bin"
MARKER="$TMP_DIR/fake-agent-ran"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
echo ran > "$MARKER"
exit 1
EOF
chmod +x "$FAKE_BIN/codex"

MATCH_REPO="$TMP_DIR/match"
MATCH_OUT="$TMP_DIR/match.out"
make_repo "$MATCH_REPO" "loop/test"
if run_loop "$MATCH_REPO" "$MATCH_OUT" env PATH="$FAKE_BIN:$PATH" LOOP_REQUIRE_BRANCH_PREFIX="loop/"; then
  echo "Expected matching branch run to stop later because backlog is missing." >&2
  exit 1
fi
assert_contains "$MATCH_OUT" "run mode requires .loop-agent/backlog.md"
assert_not_contains "$MATCH_OUT" "run mode requires branch prefix"

MISMATCH_REPO="$TMP_DIR/mismatch"
MISMATCH_OUT="$TMP_DIR/mismatch.out"
make_repo "$MISMATCH_REPO" "feature/manual"
if run_loop "$MISMATCH_REPO" "$MISMATCH_OUT" env PATH="$FAKE_BIN:$PATH" LOOP_REQUIRE_BRANCH_PREFIX="loop/"; then
  echo "Expected non-matching branch run to fail." >&2
  exit 1
fi
assert_contains "$MISMATCH_OUT" "run mode requires branch prefix: loop/"
assert_contains "$MISMATCH_OUT" "Current branch: feature/manual"
assert_contains "$MISMATCH_OUT" "Required prefix: loop/"
if [[ -f "$MARKER" ]]; then
  echo "Fake agent should not run when branch preflight fails." >&2
  exit 1
fi

DEFAULT_REPO="$TMP_DIR/default"
DEFAULT_OUT="$TMP_DIR/default.out"
make_repo "$DEFAULT_REPO" "feature/manual"
if run_loop "$DEFAULT_REPO" "$DEFAULT_OUT" env PATH="$FAKE_BIN:$PATH"; then
  echo "Expected default run to stop later because backlog is missing." >&2
  exit 1
fi
assert_contains "$DEFAULT_OUT" "run mode requires .loop-agent/backlog.md"
assert_not_contains "$DEFAULT_OUT" "run mode requires branch prefix"

echo "e2e_branch_preflight: PASS"
