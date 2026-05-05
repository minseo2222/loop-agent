#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
COUNTER_FILE="$TMP_DIR/codex_count"
LOG_FILE="$TMP_DIR/loop.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_HOME/.codex"
printf '{}\n' > "$FAKE_HOME/.codex/auth.json"
printf '0\n' > "$COUNTER_FILE"

cat > "$PROJECT_DIR/.gitignore" <<'EOF'
.loop-agent/
EOF

cat > "$PROJECT_DIR/tracked.txt" <<'EOF'
before
EOF

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" config core.autocrlf false
git -C "$PROJECT_DIR" add .gitignore tracked.txt
git -C "$PROJECT_DIR" commit -q -m "initial"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'EOF'
# Backlog

- [ ] Task 1.1: Update tracked file
  - Depends: none
  - Files:
    - tracked.txt
  - Completion criteria:
    - tracked.txt updated
  - verify: `grep -q "implemented via git evidence" tracked.txt`
  - Fail count: 0
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count="$(cat "$FAKE_CODEX_COUNTER")"
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNTER"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Tasks

### Task 1: Update tracked file
- File: tracked.txt
- What to do: Update the tracked file.
- Completion criteria:
  - [ ] tracked.txt updated
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
    printf 'implemented via git evidence\n' >> tracked.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Update tracked file - modified tracked.txt

## Files changed
summary_only.txt

## Completion criteria status
- [x] verify: `grep -q "implemented via git evidence" tracked.txt`
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
    echo "unexpected codex call $count" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/codex"

if ! HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" FAKE_CODEX_COUNTER="$COUNTER_FILE" COMMIT_ON_PASS=0 bash "$ROOT_DIR/loop.sh" 1 "$PROJECT_DIR" > "$LOG_FILE" 2>&1; then
  cat "$LOG_FILE" >&2
  exit 1
fi

EVIDENCE_DIR="$PROJECT_DIR/.loop-agent/evidence/loop-1"
for file in status.txt changed_files.txt diff_stat.txt diff.patch git_exit_codes.txt; do
  if [[ ! -f "$EVIDENCE_DIR/$file" ]]; then
    echo "missing evidence file: $file" >&2
    exit 1
  fi
done

grep -q 'tracked.txt' "$EVIDENCE_DIR/status.txt"
grep -Fxq 'tracked.txt' "$EVIDENCE_DIR/changed_files.txt"
if grep -q 'summary_only.txt' "$EVIDENCE_DIR/changed_files.txt"; then
  echo "changed_files.txt used implementer summary content" >&2
  exit 1
fi

grep -q 'tracked.txt' "$EVIDENCE_DIR/diff_stat.txt"
grep -q '+implemented via git evidence' "$EVIDENCE_DIR/diff.patch"

grep -q '^status=0$' "$EVIDENCE_DIR/git_exit_codes.txt"
grep -q '^changed_files=0$' "$EVIDENCE_DIR/git_exit_codes.txt"
grep -q '^diff_stat=0$' "$EVIDENCE_DIR/git_exit_codes.txt"
grep -q '^diff=0$' "$EVIDENCE_DIR/git_exit_codes.txt"

echo "PASS"
