#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
FAKE_BIN="$TMP/bin"
HOME_DIR="$TMP/home"
mkdir -p "$PROJECT/.loop-agent" "$FAKE_BIN" "$HOME_DIR/.codex"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"

cat > "$PROJECT/.loop-agent/backlog.md" <<'EOF'
# Backlog

- [ ] Task T1: Pass handler fixture
  - Files:
    - `app.txt`
  - Verify:
    - `test -f app.txt`
  - Completion criteria:
    - PASS creates app file.
  - Fail count: 0
EOF

semantic_snapshot() {
  grep -E 'Task T1:|Files:|Verify:|app.txt|test -f app.txt|Completion criteria:|PASS creates app file' \
    "$PROJECT/.loop-agent/backlog.md" | sed 's/^- \[[ x]\] /- [ ] /'
}
semantic_snapshot > "$TMP/semantic.before"

cat > "$FAKE_BIN/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF

cat > "$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "get" && "${3:-}" == "prefix" ]]; then
  pwd
fi
EOF

cat > "$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  count="$(cat "$FAKE_CODEX_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_CODEX_COUNT_FILE"

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Create app.txt for the fixture.

## Tasks

### Task 1: Fixture change
- File: app.txt
- What to do: Create app.txt.
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
    printf 'pass handler fixture\n' > app.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Fixture change - created app.txt.

## Completion criteria status
- [x] verify: `test -f app.txt`
OUT
    ;;
  4)
    cat <<'OUT'
# Impl Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
  *)
    echo "unexpected codex call $count" >&2
    exit 1
    ;;
esac
EOF

cat > "$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
base="$(basename "$script")"

if [[ "$base" == "progress_window.py" ]]; then
  if [[ "${1:-}" == "--truncate" ]]; then
    exit 0
  fi
  cat "$1"
  exit 0
fi

if [[ "$base" != "backlog_manager.py" ]]; then
  echo "unexpected python target: $base" >&2
  exit 1
fi

cmd="$1"
backlog="${2:-}"
is_complete() {
  grep -q '^- \[x\] Task T1:' "$backlog" 2>/dev/null
}

case "$cmd" in
  status)
    if is_complete; then
      echo '{"complete": true, "pending": 0, "blocked": 0}'
    else
      echo '{"complete": false, "pending": 1, "blocked": 0}'
    fi
    ;;
  next)
    if is_complete; then
      echo '{}'
    else
      echo '{"id": "T1", "name": "Pass handler fixture"}'
    fi
    ;;
  verify)
    echo 'test -f app.txt'
    ;;
  files)
    echo 'app.txt'
    ;;
  semantic-snapshot)
    grep -E 'Task T1:|Files:|Verify:|app.txt|test -f app.txt|Completion criteria:|PASS creates app file' "$backlog" \
      | sed 's/^- \[[ x]\] /- [ ] /'
    ;;
  complete)
    project_dir="$(cd "$(dirname "$backlog")/.." && pwd)"
    echo "complete $(git -C "$project_dir" rev-parse HEAD)" >> "$(dirname "$backlog")/manager_events.log"
    sed -i.bak 's/^- \[ \] Task T1:/- [x] Task T1:/' "$backlog"
    rm -f "$backlog.bak"
    echo OK
    ;;
  compact)
    echo 'NO_CHANGE: fake'
    ;;
  progress)
    echo 'Progress: fake'
    ;;
  lint)
    echo OK
    ;;
  fail|expand)
    echo OK
    ;;
  *)
    echo "unexpected backlog_manager command: $cmd" >&2
    exit 1
    ;;
esac
EOF
cp "$FAKE_BIN/python3" "$FAKE_BIN/python"
chmod +x "$FAKE_BIN/envsubst" "$FAKE_BIN/npm" "$FAKE_BIN/timeout" "$FAKE_BIN/codex" "$FAKE_BIN/python3" "$FAKE_BIN/python"

export PATH="$FAKE_BIN:$PATH"
export HOME="$HOME_DIR"
export FAKE_CODEX_COUNT_FILE="$TMP/codex_count"
export GIT_AUTHOR_NAME="Loop Test"
export GIT_AUTHOR_EMAIL="loop-test@example.com"
export GIT_COMMITTER_NAME="Loop Test"
export GIT_COMMITTER_EMAIL="loop-test@example.com"

if ! COMMIT_ON_PASS=1 LOOP_VERIFY_TIMEOUT=30 bash "$ROOT/loop.sh" run --iterations 1 --project "$PROJECT" > "$TMP/run.out" 2>&1; then
  cat "$TMP/run.out" >&2
  exit 1
fi

test -f "$PROJECT/app.txt"

pass_commit="$(git -C "$PROJECT" rev-parse HEAD)"
git -C "$PROJECT" log -1 --pretty=%s | grep -Fx 'loop-agent: PASS T1 loop 1' >/dev/null
git -C "$PROJECT" show --name-only --pretty='' "$pass_commit" | grep -Fx 'app.txt' >/dev/null

grep -Fx "complete $pass_commit" "$PROJECT/.loop-agent/manager_events.log" >/dev/null
grep -F "PASS commit: $pass_commit" "$PROJECT/.loop-agent/progress.txt" >/dev/null
grep -F "PASS commit:** $pass_commit" "$PROJECT/.loop-agent/report.md" >/dev/null
grep -F "Evidence: .loop-agent/evidence/loop-1/" "$PROJECT/.loop-agent/progress.txt" >/dev/null
grep -F "Evidence:** .loop-agent/evidence/loop-1/" "$PROJECT/.loop-agent/report.md" >/dev/null
grep -F "PASS commit: $pass_commit" "$PROJECT/.loop-agent/evidence/loop-1/pass_result.md" >/dev/null
grep -F "Evidence: .loop-agent/evidence/loop-1/" "$PROJECT/.loop-agent/evidence/loop-1/pass_result.md" >/dev/null

semantic_snapshot > "$TMP/semantic.after"
cmp -s "$TMP/semantic.before" "$TMP/semantic.after"

[[ -z "$(git -C "$PROJECT" status --porcelain)" ]]
