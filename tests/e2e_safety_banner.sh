#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJECT="$TMP_ROOT/project"
BIN_DIR="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$PROJECT/.loop-agent" "$BIN_DIR" "$HOME_DIR/.codex"

cat > "$HOME_DIR/.codex/auth.json" <<'EOF'
{}
EOF

cat > "$PROJECT/app.txt" <<'EOF'
initial
EOF

cat > "$PROJECT/.loop-agent/backlog.md" <<'EOF'
# Backlog

## Tasks

- [ ] Task 1.1: Update app file
  - Size: Small
  - Files:
    - `app.txt`
  - Description: Update app.txt so the run has a project change.
  - Completion criteria:
    - [ ] app.txt contains the fake implementation marker.
    - [ ] verify: `grep -q fake-implementation app.txt`
  - Depends: none
  - Fail count: 0
EOF

cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${FAKE_CODEX_STATE:?}"
count=0
if [[ -f "$state_file" ]]; then
  count="$(cat "$state_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$state_file"

cat >/dev/null

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Steps
- Update app.txt.

VERDICT: PASS
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
    printf '%s\n' 'fake-implementation' >> app.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Update app file

## Completion criteria status
- [x] app.txt contains the fake implementation marker.
OUT
    ;;
  4)
    cat <<'OUT'
# Implementation Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
  *)
    echo "Unexpected codex call: $count" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$BIN_DIR/codex"

git -C "$PROJECT" init -q
git -C "$PROJECT" config core.autocrlf false
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" add app.txt .loop-agent/backlog.md
git -C "$PROJECT" commit -q -m "initial"

OUTPUT="$TMP_ROOT/output.txt"
set +e
timeout 60 env \
  PATH="$BIN_DIR:$PATH" \
  HOME="$HOME_DIR" \
  FAKE_CODEX_STATE="$TMP_ROOT/codex-count" \
  COMMIT_ON_PASS=0 \
  LOOP_RISK_MODE=safe \
  bash "$ROOT_DIR/loop.sh" run --project "$PROJECT" --iterations 1 --cli codex \
  < /dev/null > "$OUTPUT" 2>&1
status=$?
set -e
if [[ "$status" -eq 124 ]]; then
  cat "$OUTPUT"
  echo "loop-agent run timed out" >&2
  exit 1
fi

require_output() {
  local expected="$1"
  if ! grep -Fq "$expected" "$OUTPUT"; then
    echo "Missing expected output: $expected" >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
}

reject_output() {
  local unexpected="$1"
  if grep -Fq "$unexpected" "$OUTPUT"; then
    echo "Unexpected interactive output: $unexpected" >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
}

require_output "Run Safety Summary"
require_output "Project path:"
require_output "$PROJECT"
require_output "CLI:"
require_output "codex"
require_output "Risk mode:"
require_output "safe"
require_output "Clean tree:"
require_output "clean"
require_output "Branch requirement:"
require_output "not required"
require_output "Backlog lint:"
require_output "passed"

reject_output "Approve ("
reject_output "Please review and approve backlog.md"
