#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/bin"
FAKE_HOME="$TMP_DIR/home"
RUN_OUT="$TMP_DIR/run.out"
COUNT_FILE="$TMP_DIR/codex-count"

mkdir -p "$FAKE_BIN" "$FAKE_HOME/.codex"
cp -a "$ROOT_DIR/." "$REPO"
rm -rf "$REPO/.git" "$REPO/.loop-agent"

cat > "$FAKE_HOME/.codex/auth.json" <<'JSON'
{}
JSON

cat > "$FAKE_BIN/codex" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "exec" ]]; then
  shift
fi

cat >/dev/null || true

count_file="${FAKE_CODEX_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$count" in
  1)
    cat <<'EOF'
# Plan

## Tasks
- Task 1: Update work.txt.
EOF
    ;;
  2)
    cat <<'EOF'
# Plan Critique

## Notes
none

VERDICT: PASS
EOF
    ;;
  3)
    printf '\nimplemented\n' >> work.txt
    cat <<'EOF'
# Implementation Summary

## Tasks completed
- [x] Task 1: Update work.txt

## Completion criteria status
- [x] verify: `grep -q implemented work.txt`
EOF
    ;;
  4)
    cat <<'EOF'
# Impl Critique

## Notes
none

VERDICT: PASS
EOF
    ;;
  *)
    echo "VERDICT: PASS"
    ;;
esac
BASH
chmod +x "$FAKE_BIN/codex"

git -C "$REPO" init -q
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
printf 'initial\n' > "$REPO/work.txt"
git -C "$REPO" add .
git -C "$REPO" commit -q -m "initial"

mkdir -p \
  "$REPO/.loop-agent/evidence/loop-0" \
  "$REPO/.loop-agent/evidence/loop-2" \
  "$REPO/.loop-agent/evidence/loop-3"
printf 'old\n' > "$REPO/.loop-agent/evidence/loop-0/old.txt"
printf 'blocked\n' > "$REPO/.loop-agent/evidence/loop-2/blocked.txt"
printf 'recent\n' > "$REPO/.loop-agent/evidence/loop-3/recent.txt"

cat > "$REPO/.loop-agent/backlog.md" <<'EOF'
# Backlog

- [ ] Task 1.1: Update work file
  - Size: Small
  - Files:
    - work.txt
  - Description: Update the work file.
  - Completion criteria:
    - [ ] work file contains implemented
    - [ ] verify: `grep -q implemented work.txt`
  - Depends: none
  - Fail count: 0

- [!] Task 1.2: Already blocked
  - Size: Small
  - Files:
    - blocked.txt
  - Description: This task is blocked.
  - Completion criteria:
    - [ ] verify: `true`
  - Depends: none
  - Fail count: 5
  - Status: BLOCKED
  - Evidence path: .loop-agent/evidence/loop-2/
EOF

if ! PATH="$FAKE_BIN:$PATH" \
  HOME="$FAKE_HOME" \
  FAKE_CODEX_COUNT_FILE="$COUNT_FILE" \
  COMMIT_ON_PASS=0 \
  LOOP_EVIDENCE_KEEP_RUNS=1 \
  bash "$REPO/loop.sh" 1 "$REPO" codex > "$RUN_OUT" 2>&1; then
  cat "$RUN_OUT" >&2
  fail "loop-agent run failed"
fi

[[ -d "$REPO/.loop-agent/evidence/loop-1" ]] || fail "current evidence directory was removed"
[[ -d "$REPO/.loop-agent/evidence/loop-2" ]] || fail "blocked-task evidence directory was removed"
[[ -d "$REPO/.loop-agent/evidence/loop-3" ]] || fail "newest retained evidence directory was removed"

if [[ -d "$REPO/.loop-agent/evidence/loop-0" ]]; then
  fail "old unprotected evidence directory still exists"
fi

if [[ ! -f "$REPO/.loop-agent/evidence/loop-0.tar.gz" && ! -f "$REPO/.loop-agent/evidence/loop-0.compacted.md" ]]; then
  fail "old unprotected evidence was neither archived nor compacted"
fi

echo "PASS"
