#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_SH="$ROOT/loop.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  local pid
  for pid in ${PIDS:-}; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_fake_tools() {
  mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/.codex"
  printf '{}\n' > "$TMP_ROOT/home/.codex/auth.json"

  cat > "$TMP_ROOT/bin/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH

  cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
prompt="$(cat)"
count_file=".fake_codex_count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

if [[ "${FAKE_CODEX_SLEEP:-0}" != "0" ]]; then
  sleep "$FAKE_CODEX_SLEEP"
fi

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Touch fixture.

## Tasks

### Task 1: Touch fixture
- File: fixture.txt
- Completion criteria:
  - [ ] verify: `true`
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
    printf 'change\n' >> fixture.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Touch fixture
OUT
    ;;
  *)
    cat <<'OUT'
# Implementation Critique

## Notes
none

VERDICT: PASS
OUT
    ;;
esac
SH

  chmod +x "$TMP_ROOT/bin/envsubst" "$TMP_ROOT/bin/codex"
  export PATH="$TMP_ROOT/bin:$PATH"
  export HOME="$TMP_ROOT/home"
}

make_project() {
  local name="$1"
  local project="$TMP_ROOT/$name"
  mkdir -p "$project/.loop-agent"
  printf 'initial\n' > "$project/fixture.txt"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

- [ ] Task 1.1: Touch fixture
  - File: fixture.txt
  - Completion criteria:
    - [ ] Fixture changes.
    - [ ] verify: `true`
MD
  git -C "$project" init -q
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" add -A
  git -C "$project" commit -q -m "initial"
  printf '%s\n' "$project"
}

lock_pid() {
  sed -n 's/^pid=//p' "$1/.loop-agent/loop.lock" 2>/dev/null | head -1 | tr -d '\r'
}

wait_for_lock() {
  local project="$1"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if [[ -f "$project/.loop-agent/loop.lock" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_pid_change() {
  local project="$1"
  local stale_pid="$2"
  local deadline=$((SECONDS + 10))
  local pid
  while (( SECONDS < deadline )); do
    pid="$(lock_pid "$project")"
    if [[ -n "$pid" && "$pid" != "$stale_pid" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

run_loop_bg() {
  local project="$1"
  local output="$2"
  FAKE_CODEX_SLEEP="${3:-5}" COMMIT_ON_PASS=0 LOOP_VERIFY_TIMEOUT=10 "$LOOP_SH" 1 "$project" codex > "$output" 2>&1 &
  RUN_PID=$!
  PIDS="${PIDS:-} $RUN_PID"
}

stop_pid() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

write_fake_tools

project_live="$(make_project live)"
out_live="$TMP_ROOT/live.out"
run_loop_bg "$project_live" "$out_live" 5
pid_live="$RUN_PID"
wait_for_lock "$project_live" || fail "lock was not created during a run"
grep -q '^pid=' "$project_live/.loop-agent/loop.lock" || fail "lock does not record pid"
grep -q '^command=' "$project_live/.loop-agent/loop.lock" || fail "lock does not record command"
grep -q '^started_utc=' "$project_live/.loop-agent/loop.lock" || fail "lock does not record start time"
out_reject="$TMP_ROOT/reject.out"
if COMMIT_ON_PASS=0 "$LOOP_SH" 1 "$project_live" codex > "$out_reject" 2>&1; then
  fail "second run succeeded while live lock existed"
fi
grep -q 'Another loop-agent run is active' "$out_reject" || fail "live lock rejection message was not clear"
stop_pid "$pid_live"
[[ ! -e "$project_live/.loop-agent/loop.lock" ]] || fail "TERM cleanup did not remove lock file"
[[ ! -e "$project_live/.loop-agent/loop.lock.d" ]] || fail "TERM cleanup did not remove lock directory"

project_stale="$(make_project stale)"
stale_pid="999999"
mkdir -p "$project_stale/.loop-agent/loop.lock.d"
{
  printf 'pid=%s\n' "$stale_pid"
  printf 'command=old\n'
  printf 'started_utc=2000-01-01T00:00:00Z\n'
} > "$project_stale/.loop-agent/loop.lock"
out_stale="$TMP_ROOT/stale.out"
run_loop_bg "$project_stale" "$out_stale" 5
pid_stale_run="$RUN_PID"
wait_for_pid_change "$project_stale" "$stale_pid" || fail "stale lock replacement was not observed"
grep -q '^command=' "$project_stale/.loop-agent/loop.lock" || fail "replacement lock does not record command"
grep -q '^started_utc=' "$project_stale/.loop-agent/loop.lock" || fail "replacement lock does not record start time"
stop_pid "$pid_stale_run"

project_normal="$(make_project normal)"
out_normal="$TMP_ROOT/normal.out"
FAKE_CODEX_SLEEP=0 COMMIT_ON_PASS=0 LOOP_VERIFY_TIMEOUT=10 "$LOOP_SH" 1 "$project_normal" codex > "$out_normal" 2>&1 || true
[[ ! -e "$project_normal/.loop-agent/loop.lock" ]] || fail "normal exit did not remove lock file"
[[ ! -e "$project_normal/.loop-agent/loop.lock.d" ]] || fail "normal exit did not remove lock directory"

project_modes="$(make_project modes)"
"$LOOP_SH" status --project "$project_modes" > "$TMP_ROOT/status.out" 2>&1 || fail "status failed"
"$LOOP_SH" doctor --project "$project_modes" > "$TMP_ROOT/doctor.out" 2>&1 || fail "doctor failed"
[[ ! -e "$project_modes/.loop-agent/loop.lock" ]] || fail "status or doctor created a lock"
project_init="$TMP_ROOT/init"
mkdir -p "$project_init"
git -C "$project_init" init -q
printf 'n\n' | FAKE_CODEX_SLEEP=0 "$LOOP_SH" init --project "$project_init" > "$TMP_ROOT/init.out" 2>&1 || true
[[ ! -e "$project_init/.loop-agent/loop.lock" ]] || fail "init created a lock"

project_concurrent="$(make_project concurrent)"
out_one="$TMP_ROOT/concurrent-one.out"
out_two="$TMP_ROOT/concurrent-two.out"
run_loop_bg "$project_concurrent" "$out_one" 6
pid_one="$RUN_PID"
run_loop_bg "$project_concurrent" "$out_two" 6
pid_two="$RUN_PID"
wait_for_lock "$project_concurrent" || fail "concurrent run did not create a lock"
deadline=$((SECONDS + 10))
while kill -0 "$pid_one" 2>/dev/null && kill -0 "$pid_two" 2>/dev/null && (( SECONDS < deadline )); do
  sleep 0.1
done
if kill -0 "$pid_one" 2>/dev/null && kill -0 "$pid_two" 2>/dev/null; then
  fail "two concurrent initially unlocked runs both proceeded"
fi
if kill -0 "$pid_one" 2>/dev/null; then
  active_pid="$pid_one"
  rejected_pid="$pid_two"
  rejected_out="$out_two"
else
  active_pid="$pid_two"
  rejected_pid="$pid_one"
  rejected_out="$out_one"
fi
if wait "$rejected_pid" 2>/dev/null; then
  fail "rejected concurrent run exited successfully"
fi
grep -q 'Another loop-agent run is active' "$rejected_out" || fail "concurrent rejected run did not report the lock"
stop_pid "$active_pid"
[[ ! -e "$project_concurrent/.loop-agent/loop.lock" ]] || fail "concurrent active run did not clean lock"

echo "PASS"
