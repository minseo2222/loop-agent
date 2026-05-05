#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_CODEX_MARKER="$TMP_DIR/codex.invoked"
FAKE_GEMINI_MARKER="$TMP_DIR/gemini.invoked"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<< "$haystack"; then
    echo "$haystack" >&2
    fail "missing output: $needle"
  fi
}

snapshot_status() {
  git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=all | LC_ALL=C sort
}

snapshot_files() {
  (
    cd "$PROJECT_DIR"
    find . -type f ! -path './.git/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  )
}

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'BACKLOG'
# Backlog

## Tasks

- [ ] Task 1: Sample task
  - File: tracked.txt
  - What to do: Keep the file unchanged.
  - Completion criteria:
    - [ ] verify: `true`
BACKLOG

cat > "$PROJECT_DIR/tracked.txt" <<'TXT'
tracked content
TXT

cat > "$PROJECT_DIR/untracked.txt" <<'TXT'
existing untracked content
TXT

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
touch "$FAKE_CODEX_MARKER"
exit 99
SH

cat > "$FAKE_BIN/gemini" <<'SH'
#!/usr/bin/env bash
touch "$FAKE_GEMINI_MARKER"
exit 99
SH

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gemini"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "doctor@example.invalid"
git -C "$PROJECT_DIR" config user.name "Doctor Test"
git -C "$PROJECT_DIR" add tracked.txt .loop-agent/backlog.md
git -C "$PROJECT_DIR" commit -q -m "initial"

before_status="$TMP_DIR/status.before"
after_status="$TMP_DIR/status.after"
before_files="$TMP_DIR/files.before"
after_files="$TMP_DIR/files.after"

snapshot_status > "$before_status"
snapshot_files > "$before_files"
before_untracked_checksum="$(sha256sum "$PROJECT_DIR/untracked.txt")"

doctor_output_codex="$(FAKE_CODEX_MARKER="$FAKE_CODEX_MARKER" FAKE_GEMINI_MARKER="$FAKE_GEMINI_MARKER" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/loop.sh" doctor --project "$PROJECT_DIR" --cli codex 2>&1)"
doctor_output_gemini="$(FAKE_CODEX_MARKER="$FAKE_CODEX_MARKER" FAKE_GEMINI_MARKER="$FAKE_GEMINI_MARKER" PATH="$FAKE_BIN:$PATH" "$ROOT_DIR/loop.sh" doctor --project "$PROJECT_DIR" --cli gemini 2>&1)"
doctor_output="$doctor_output_codex
$doctor_output_gemini"

assert_contains "$doctor_output" "Git:"
assert_contains "$doctor_output" "Python:"
assert_contains "$doctor_output" "Bash:"
assert_contains "$doctor_output" "AI CLI (codex): available"
assert_contains "$doctor_output" "AI CLI (gemini): available"
assert_contains "$doctor_output" "Backlog:"
assert_contains "$doctor_output" "Backlog lint:"
assert_contains "$doctor_output" "Clean tree:"
assert_contains "$doctor_output" "Clean tree: dirty"

if [[ -e "$FAKE_CODEX_MARKER" ]]; then
  fail "codex was invoked"
fi

if [[ -e "$FAKE_GEMINI_MARKER" ]]; then
  fail "gemini was invoked"
fi

snapshot_status > "$after_status"
snapshot_files > "$after_files"
after_untracked_checksum="$(sha256sum "$PROJECT_DIR/untracked.txt")"

if ! cmp -s "$before_status" "$after_status"; then
  diff -u "$before_status" "$after_status" >&2 || true
  fail "git status changed"
fi

if ! cmp -s "$before_files" "$after_files"; then
  diff -u "$before_files" "$after_files" >&2 || true
  fail "project file contents changed"
fi

if [[ "$before_untracked_checksum" != "$after_untracked_checksum" ]]; then
  fail "existing untracked file changed"
fi

echo "PASS: doctor command diagnostics are read-only"
