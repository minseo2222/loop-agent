#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
AGENT_LOG="$TMP_DIR/agent.log"

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

- [x] Task 1.1: Already complete
  - Files:
    - done.txt
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - Done.
  - verify: echo done
BACKLOG

cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
echo "codex was called: \$*" >> "$AGENT_LOG"
exit 97
EOF
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
chmod +x "$FAKE_BIN/envsubst"

set +e
OUTPUT="$(
  PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" \
    GIT_AUTHOR_NAME="Loop Test" GIT_AUTHOR_EMAIL="loop-test@example.com" \
    GIT_COMMITTER_NAME="Loop Test" GIT_COMMITTER_EMAIL="loop-test@example.com" \
    bash "$REPO_ROOT/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex 2>&1
)"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  printf 'expected exit 0, got %s\n%s\n' "$STATUS" "$OUTPUT" >&2
  exit 1
fi

BACKLOG_FILE="$PROJECT_DIR/.loop-agent/backlog.md"
if ! grep -F -- "- [x] Task 1.1: Already complete" "$BACKLOG_FILE" >/dev/null; then
  printf 'expected completed task marker to remain\n' >&2
  cat "$BACKLOG_FILE" >&2
  exit 1
fi

if grep -F -- "- [!] Task" "$BACKLOG_FILE" >/dev/null; then
  printf 'unexpected blocked marker in completed backlog\n' >&2
  cat "$BACKLOG_FILE" >&2
  exit 1
fi

if grep -F -- '[!\]' "$BACKLOG_FILE" >/dev/null || grep -F -- '[!\]' <<< "$OUTPUT" >/dev/null; then
  printf 'unexpected malformed blocked marker\n' >&2
  cat "$BACKLOG_FILE" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi

if ! grep -q "All tasks complete" <<< "$OUTPUT"; then
  printf 'expected all-tasks-complete output\n%s\n' "$OUTPUT" >&2
  exit 1
fi

if grep -qi "no PASS" <<< "$OUTPUT"; then
  printf 'unexpected no-PASS guidance\n%s\n' "$OUTPUT" >&2
  exit 1
fi

if grep -Eq "Phase [0-9]|Planner|Plan Critic|Implementer|Impl Critic" <<< "$OUTPUT"; then
  printf 'unexpected agent phase output\n%s\n' "$OUTPUT" >&2
  exit 1
fi

if [[ -s "$AGENT_LOG" ]]; then
  printf 'unexpected agent CLI call\n' >&2
  cat "$AGENT_LOG" >&2
  exit 1
fi
