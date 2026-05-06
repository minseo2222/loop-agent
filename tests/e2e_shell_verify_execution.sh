#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"
FAKE_STATE="$TMP_DIR/fake-state"
mkdir -p "$PROJECT_DIR/.loop-agent" "$BIN_DIR" "$FAKE_STATE" "$TMP_DIR/home/.codex"
printf '{}\n' > "$TMP_DIR/home/.codex/auth.json"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

## Tasks
- [ ] Task 1.1: Shell verify execution
  - Status: pending
  - Depends: none
  - Fail count: 0
  - Files:
    - `src/output.txt`
  - Completion criteria:
    - [ ] Allowed implementation file is changed.
    - [ ] verify: `printf 'first\n' >> verify_order.txt`
    - [ ] verify: `printf 'second-out\n'; printf 'second-err\n' >&2; printf 'second\n' >> verify_order.txt`
    - [ ] verify: `printf 'third-out\n'; printf 'third-err\n' >&2; printf 'third\n' >> verify_order.txt; exit 7`
BACKLOG

cat > "$BIN_DIR/envsubst" <<'ENVSTUB'
#!/usr/bin/env bash
cat
ENVSTUB

cat > "$BIN_DIR/timeout" <<'TIMEOUTSTUB'
#!/usr/bin/env bash
shift
exec "$@"
TIMEOUTSTUB

cat > "$BIN_DIR/codex" <<'CODEXSTUB'
#!/usr/bin/env bash
set -euo pipefail

count_file="$FAKE_CODEX_STATE/count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'PLAN'
# Plan

## Goal
Run shell verify commands.

## Tasks

### Task 1: Shell verify execution
- File: src/output.txt
- What to do: Write the allowed output file.
- Completion criteria:
  - [ ] verify commands run.
PLAN
    ;;
  2)
    cat <<'CRITIQUE'
VERDICT: PASS

## Notes
none
CRITIQUE
    ;;
  3)
    mkdir -p src
    printf 'implemented\n' > src/output.txt
    cat <<'SUMMARY'
# Implementation Summary

## Tasks completed
- [x] Task 1: Shell verify execution - wrote the allowed file.
SUMMARY
    ;;
  4)
    cat <<'IMPLCRITIQUE'
VERDICT: PASS

## Notes
none
IMPLCRITIQUE
    ;;
  *)
    echo "unexpected codex call $count" >&2
    exit 1
    ;;
esac
CODEXSTUB

chmod +x "$BIN_DIR/envsubst" "$BIN_DIR/timeout" "$BIN_DIR/codex"

PATH="$BIN_DIR:$PATH" \
HOME="$TMP_DIR/home" \
FAKE_CODEX_STATE="$FAKE_STATE" \
GIT_AUTHOR_NAME="Loop Test" \
GIT_AUTHOR_EMAIL="loop-test@example.com" \
GIT_COMMITTER_NAME="Loop Test" \
GIT_COMMITTER_EMAIL="loop-test@example.com" \
COMMIT_ON_PASS=0 \
LOOP_VERIFY_TIMEOUT=20 \
bash "$REPO_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex \
  > "$TMP_DIR/loop.out" 2> "$TMP_DIR/loop.err" || {
    cat "$TMP_DIR/loop.out"
    cat "$TMP_DIR/loop.err" >&2
    exit 1
  }

EVIDENCE_DIR="$PROJECT_DIR/.loop-agent/evidence/loop-1"
test -f "$EVIDENCE_DIR/verify_commands.txt"
test -f "$EVIDENCE_DIR/verify_results.md"
test -f "$EVIDENCE_DIR/verify_exit_codes.txt"

printf 'first\nsecond\nthird\n' > "$TMP_DIR/expected_order.txt"
cmp "$TMP_DIR/expected_order.txt" "$PROJECT_DIR/verify_order.txt"

grep -F "command_3=FAIL exit=7" "$EVIDENCE_DIR/verify_exit_codes.txt" >/dev/null
grep -F "stdout: .loop-agent/evidence/loop-1/verify_command_2.stdout" "$EVIDENCE_DIR/verify_results.md" >/dev/null
grep -F "stderr: .loop-agent/evidence/loop-1/verify_command_2.stderr" "$EVIDENCE_DIR/verify_results.md" >/dev/null
grep -F "second-out" "$EVIDENCE_DIR/verify_command_2.stdout" >/dev/null
grep -F "second-err" "$EVIDENCE_DIR/verify_command_2.stderr" >/dev/null
grep -F "third-out" "$EVIDENCE_DIR/verify_command_3.stdout" >/dev/null
grep -F "third-err" "$EVIDENCE_DIR/verify_command_3.stderr" >/dev/null
