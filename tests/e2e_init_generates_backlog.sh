#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PROJECT="$TMP_DIR/project"
RUN_PROJECT="$TMP_DIR/run-project"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
LOG="$TMP_DIR/fake-cli.log"
COUNT="$TMP_DIR/fake-cli-count"
RUN_LOG="$TMP_DIR/run-fake-cli.log"
RUN_COUNT="$TMP_DIR/run-fake-cli-count"

mkdir -p "$PROJECT" "$RUN_PROJECT" "$BIN_DIR" "$HOME_DIR/.codex"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"
printf '# Test Project\n' > "$PROJECT/README.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email "test@example.com"
git -C "$PROJECT" config user.name "Test User"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m "initial"

cat > "$BIN_DIR/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH
chmod +x "$BIN_DIR/envsubst"

cat > "$BIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

count_file="${FAKE_CODEX_COUNT:?}"
log_file="${FAKE_CLI_LOG:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
cat >/dev/null

case "$count" in
  1)
    echo "Setup Agent" >> "$log_file"
    cat <<'EOF'
# Project Backlog

- [ ] Task 1: Test task
  - File: README.md
  - Fail count: 0
EOF
    ;;
  2)
    echo "Setup Critic" >> "$log_file"
    cat <<'EOF'
VERDICT: PASS

## Notes
none
EOF
    ;;
  3)
    echo "Planner" >> "$log_file"
    echo "VERDICT: PASS"
    ;;
  4)
    echo "Plan Critic" >> "$log_file"
    echo "VERDICT: PASS"
    ;;
  5)
    echo "Implementer" >> "$log_file"
    echo "# Implementation Summary"
    ;;
  *)
    echo "Unexpected phase $count" >> "$log_file"
    echo "VERDICT: PASS"
    ;;
esac
SH
chmod +x "$BIN_DIR/codex"

(
  cd "$ROOT"
  printf 'y\n' | HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_CLI_LOG="$LOG" FAKE_CODEX_COUNT="$COUNT" \
    ./loop.sh init --project "$PROJECT" --cli codex > "$TMP_DIR/init.out" 2> "$TMP_DIR/init.err"
)

[[ -f "$PROJECT/.loop-agent/backlog.md" ]] || fail "init did not create backlog.md"
grep -q "Setup Agent" "$LOG" || fail "init did not invoke setup agent"
grep -q "Setup Critic" "$LOG" || fail "init did not invoke setup critic"
! grep -q "Planner" "$LOG" || fail "init started Planner"
! grep -q "Implementer" "$LOG" || fail "init started Implementer"
! grep -q "Phase 1 .* Planner" "$TMP_DIR/init.out" || fail "init output entered Planner phase"
! grep -q "Phase 3 .* Implementer" "$TMP_DIR/init.out" || fail "init output entered Implementer phase"

set +e
(
  cd "$ROOT"
  HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" FAKE_CLI_LOG="$RUN_LOG" FAKE_CODEX_COUNT="$RUN_COUNT" \
    ./loop.sh run --project "$RUN_PROJECT" --iterations 1 --cli codex > "$TMP_DIR/run.out" 2> "$TMP_DIR/run.err"
)
run_status=$?
set -e

[[ "$run_status" -ne 0 ]] || fail "explicit run without backlog succeeded"
[[ ! -e "$RUN_LOG" ]] || fail "explicit run without backlog invoked setup or CLI"
[[ ! -f "$RUN_PROJECT/.loop-agent/backlog.md" ]] || fail "explicit run without backlog created backlog.md"
grep -q "run mode requires .loop-agent/backlog.md" "$TMP_DIR/run.err" || fail "explicit run did not report missing backlog"
