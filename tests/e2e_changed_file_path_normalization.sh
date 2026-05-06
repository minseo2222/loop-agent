#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
COUNT_FILE="$TMP_DIR/codex-count"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fqx "$expected" "$file" || fail "expected $file to contain line: $expected"
}

assert_not_contains_text() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    fail "did not expect $file to contain: $unexpected"
  fi
}

assert_no_absolute_paths() {
  local file="$1"
  if grep -Eq '(^/|^[A-Za-z]:[\\/])' "$file"; then
    echo "File contains absolute path:" >&2
    cat "$file" >&2
    exit 1
  fi
}

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$HOME_DIR/.codex"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"

cat > "$FAKE_BIN/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
chmod +x "$FAKE_BIN/envsubst"

cat > "$FAKE_BIN/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "get" && "${3:-}" == "prefix" ]]; then
  exit 0
fi
exit 0
SH
chmod +x "$FAKE_BIN/npm"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

count="$(cat "$CODEX_CALL_COUNT_FILE" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" > "$CODEX_CALL_COUNT_FILE"

case "$count" in
  1)
    printf '# Plan\n\nNo-op fake plan.\n'
    ;;
  2)
    printf 'VERDICT: PASS\n\n## Notes\nnone\n'
    ;;
  3)
    printf 'changed\n' >> 'file with spaces.txt'
    rm 'deleted file.txt'
    git mv 'old name.txt' 'new name.txt'
    printf '# Implementation Summary\n\n- [x] Fake task - changed files.\n'
    ;;
  4)
    printf 'VERDICT: PASS\n\n## Notes\nnone\n'
    ;;
  *)
    printf 'Unexpected codex call %s\n' "$count" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKE_BIN/codex"

printf 'before\n' > "$PROJECT_DIR/file with spaces.txt"
printf 'delete me\n' > "$PROJECT_DIR/deleted file.txt"
printf 'rename me\n' > "$PROJECT_DIR/old name.txt"
printf '.loop-agent/\n' > "$PROJECT_DIR/.gitignore"
cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1: Fake task
  - Files: file with spaces.txt, deleted file.txt, old name.txt, new name.txt
  - Depends: none
  - verify: echo ok
  - Fail count: 0
MD
printf '# progress\n' > "$PROJECT_DIR/.loop-agent/progress.txt"
printf '# old plan\n' > "$PROJECT_DIR/.loop-agent/plan.md"
printf '# old plan critique\n' > "$PROJECT_DIR/.loop-agent/plan_critique.md"
printf '# old impl summary\n' > "$PROJECT_DIR/.loop-agent/impl_summary.md"
printf '# old impl critique\n' > "$PROJECT_DIR/.loop-agent/impl_critique.md"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test User"
git -C "$PROJECT_DIR" config core.autocrlf false
git -C "$PROJECT_DIR" add -A
git -C "$PROJECT_DIR" add -f "$PROJECT_DIR/.loop-agent/backlog.md" \
  "$PROJECT_DIR/.loop-agent/progress.txt" \
  "$PROJECT_DIR/.loop-agent/plan.md" \
  "$PROJECT_DIR/.loop-agent/plan_critique.md" \
  "$PROJECT_DIR/.loop-agent/impl_summary.md" \
  "$PROJECT_DIR/.loop-agent/impl_critique.md"
git -C "$PROJECT_DIR" commit -q -m "initial"

PATH="$FAKE_BIN:$PATH" \
HOME="$HOME_DIR" \
CODEX_CALL_COUNT_FILE="$COUNT_FILE" \
COMMIT_ON_PASS=0 \
bash "$ROOT_DIR/loop.sh" 1 "$PROJECT_DIR" > "$TMP_DIR/loop.out" 2>"$TMP_DIR/loop.err" || {
  cat "$TMP_DIR/loop.out" >&2
  cat "$TMP_DIR/loop.err" >&2
  exit 1
}

CHANGED="$PROJECT_DIR/.loop-agent/evidence/loop-1/changed_files.txt"
STATE_CHANGED="$PROJECT_DIR/.loop-agent/evidence/loop-1/changed_state_files.txt"
RAW_CHANGED="$PROJECT_DIR/.loop-agent/evidence/loop-1/changed_files.raw"
STATUS_TXT="$PROJECT_DIR/.loop-agent/evidence/loop-1/status.txt"

[[ -f "$CHANGED" ]] || fail "missing changed_files.txt"
[[ -f "$STATE_CHANGED" ]] || fail "missing changed_state_files.txt"
[[ -s "$RAW_CHANGED" ]] || fail "missing raw changed-file evidence"
[[ -s "$STATUS_TXT" ]] || fail "missing raw git status evidence"

assert_contains "$CHANGED" "file with spaces.txt"
assert_contains "$CHANGED" "deleted file.txt"
assert_contains "$CHANGED" "old name.txt"
assert_contains "$CHANGED" "new name.txt"
assert_not_contains_text "$CHANGED" ".loop-agent/"
assert_contains "$STATE_CHANGED" ".loop-agent/progress.txt"
assert_no_absolute_paths "$CHANGED"
assert_no_absolute_paths "$STATE_CHANGED"
assert_not_contains_text "$CHANGED" "$PROJECT_DIR"
assert_not_contains_text "$STATE_CHANGED" "$PROJECT_DIR"

echo "PASS: changed file paths are normalized and state files are separated"
