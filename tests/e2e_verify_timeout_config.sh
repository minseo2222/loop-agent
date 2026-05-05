#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "exec" ]]; then
  cat >/dev/null || true
  cat <<'OUT'
VERDICT: PASS

# Implementation Summary

## Tasks completed
- [x] Task 1: Fake task

## Completion criteria status
none
OUT
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/codex"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks

- [ ] Task 1.1: Verify timeout
  - Files:
    - `allowed.txt`
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] Uses a sleeping verify command.
    - [ ] verify: `bash -lc 'echo start; sleep 3; echo done'`
EOF

export HOME="$FAKE_HOME"
export PATH="$FAKE_BIN:$PATH"
export LOOP_VERIFY_TIMEOUT=1
export COMMIT_ON_PASS=0
export GIT_AUTHOR_NAME="Loop Test"
export GIT_AUTHOR_EMAIL="loop-test@example.com"
export GIT_COMMITTER_NAME="Loop Test"
export GIT_COMMITTER_EMAIL="loop-test@example.com"

bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex >/tmp/e2e_verify_timeout_config.out 2>/tmp/e2e_verify_timeout_config.err

RESULTS="$PROJECT_DIR/.loop-agent/evidence/loop-1/verify_results.md"
EXIT_CODES="$PROJECT_DIR/.loop-agent/evidence/loop-1/verify_exit_codes.txt"

if [[ ! -f "$RESULTS" ]]; then
  echo "missing verify_results.md"
  cat /tmp/e2e_verify_timeout_config.err >&2 || true
  exit 1
fi

if [[ ! -f "$EXIT_CODES" ]]; then
  echo "missing verify_exit_codes.txt"
  cat /tmp/e2e_verify_timeout_config.err >&2 || true
  exit 1
fi

grep -q "Status: TIMEOUT" "$RESULTS"
grep -q "Timeout seconds: 1" "$RESULTS"
grep -q "command_1=TIMEOUT" "$EXIT_CODES"
grep -q "timeout=1" "$EXIT_CODES"

if grep -q "command_1=FAIL" "$EXIT_CODES"; then
  echo "timeout was recorded as ordinary verify failure"
  cat "$EXIT_CODES"
  exit 1
fi

if grep -q "Status: FAIL" "$RESULTS"; then
  echo "timeout result included ordinary failure status"
  cat "$RESULTS"
  exit 1
fi
