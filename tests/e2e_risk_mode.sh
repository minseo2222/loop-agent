#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
REAL_PYTHON="$(command -v python3 2>/dev/null || true)"
if [[ -z "$REAL_PYTHON" || "$REAL_PYTHON" == *"WindowsApps"* ]]; then
  REAL_PYTHON="$(command -v python)"
fi
export REAL_PYTHON

cat > "$FAKE_BIN/envsubst" <<'SH'
#!/usr/bin/env bash
cat
SH

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$FAKE_ARGS_LOG"
cat >/dev/null
count=0
if [[ -f "$FAKE_STAGE_FILE" ]]; then
  count="$(cat "$FAKE_STAGE_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_STAGE_FILE"
case "$count" in
  1)
    printf '# Plan\n\n## Goal\nRisk mode E2E\n'
    ;;
  2)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  3)
    printf 'changed\n' > target.txt
    printf '# Implementation Summary\n\n## Tasks completed\n- [x] Task 1: changed target.txt\n'
    ;;
  4)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  *)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
esac
SH

cat > "$FAKE_BIN/gemini" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
  printf 'fake gemini 1.0\n'
  exit 0
fi
printf 'gemini %s\n' "$*" >> "$FAKE_ARGS_LOG"
cat >/dev/null
count=0
if [[ -f "$FAKE_STAGE_FILE" ]]; then
  count="$(cat "$FAKE_STAGE_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_STAGE_FILE"
case "$count" in
  1)
    printf '# Plan\n\n## Goal\nRisk mode E2E\n'
    ;;
  2)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  3)
    printf 'changed\n' > target.txt
    printf '# Implementation Summary\n\n## Tasks completed\n- [x] Task 1: changed target.txt\n'
    ;;
  4)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
  *)
    printf '## Notes\nnone\n\nVERDICT: PASS\n'
    ;;
esac
SH

cat > "$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */backlog_manager.py ]]; then
  shift
  cmd="${1:-}"
  shift || true
  backlog="${1:-}"
  case "$cmd" in
    lint)
      exit 0
      ;;
    progress)
      if [[ -f "${backlog}.complete" ]]; then
        echo "Progress: 1/1 Tasks"
      else
        echo "Progress: 0/1 Tasks"
      fi
      ;;
    status)
      if [[ -f "${backlog}.complete" ]]; then
        echo '{"complete": true, "pending": 0, "blocked": 0}'
      else
        echo '{"complete": false, "pending": 1, "blocked": 0}'
      fi
      ;;
    next)
      echo '{"id": "Task 1.1", "name": "Risk mode fake task"}'
      ;;
    verify)
      echo 'test -s target.txt'
      ;;
    files)
      echo 'target.txt'
      ;;
    semantic-snapshot)
      echo 'snapshot'
      ;;
    fail|block)
      echo 'OK'
      ;;
    complete)
      touch "${backlog}.complete"
      echo 'OK'
      ;;
    compact)
      echo 'NO_CHANGE: none'
      ;;
    *)
      echo "unknown backlog command: $cmd" >&2
      exit 1
      ;;
  esac
  exit 0
fi
exec "$REAL_PYTHON" "$@"
SH

cp "$FAKE_BIN/python3" "$FAKE_BIN/python"

chmod +x "$FAKE_BIN/envsubst" "$FAKE_BIN/codex" "$FAKE_BIN/gemini" "$FAKE_BIN/python3" "$FAKE_BIN/python"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_project() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

## Task 1.1: Risk mode fake task
- Status: [ ]
- Size: Small
- Files:
  - target.txt
- Description: Change target.txt.
- Completion criteria:
  - [ ] target.txt is changed.
  - [ ] verify: `test -s target.txt`
- Depends: none
- Fail count: 0
MD
  printf 'initial\n' > "$project/target.txt"
  git -C "$project" init -q
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" config core.autocrlf false
  git -C "$project" add target.txt
  git -C "$project" commit -q -m "initial"
}

run_case() {
  local mode="$1"
  local cli="$2"
  local project="$TMP_DIR/project_${mode}_${cli}"
  local home="$TMP_DIR/home_${mode}_${cli}"
  local output="$TMP_DIR/output_${mode}_${cli}.txt"
  local args_log="$TMP_DIR/args_${mode}_${cli}.log"
  local stage_file="$TMP_DIR/stage_${mode}_${cli}.txt"

  make_project "$project"
  mkdir -p "$home/.codex" "$home/.gemini"
  printf '{}\n' > "$home/.codex/auth.json"
  : > "$args_log"

  if ! PATH="$FAKE_BIN:$PATH" \
      HOME="$home" \
      FAKE_ARGS_LOG="$args_log" \
      FAKE_STAGE_FILE="$stage_file" \
      LOOP_RISK_MODE="$mode" \
      COMMIT_ON_PASS=0 \
      bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" --cli "$cli" > "$output" 2>&1; then
    cat "$output" >&2
    fail "$cli $mode run failed"
  fi

  grep -q "Risk mode: $mode" "$output" || fail "$cli $mode did not print risk mode"
  grep -q "running... (cli: $cli, risk: $mode" "$output" || fail "$cli $mode did not log risk mode"

  case "$cli:$mode" in
    codex:unattended)
      grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$args_log" || fail "unattended codex omitted bypass flag"
      ;;
    codex:safe)
      ! grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$args_log" || fail "safe codex added bypass flag"
      ;;
    gemini:unattended)
      grep -q -- "--yolo" "$args_log" || fail "unattended gemini omitted --yolo"
      ;;
    gemini:safe)
      ! grep -q -- "--yolo" "$args_log" || fail "safe gemini added --yolo"
      ;;
  esac
}

run_invalid_case() {
  local project="$TMP_DIR/project_invalid"
  local home="$TMP_DIR/home_invalid"
  local output="$TMP_DIR/output_invalid.txt"
  local args_log="$TMP_DIR/args_invalid.log"

  make_project "$project"
  mkdir -p "$home/.codex"
  printf '{}\n' > "$home/.codex/auth.json"
  : > "$args_log"

  set +e
  PATH="$FAKE_BIN:$PATH" \
    HOME="$home" \
    FAKE_ARGS_LOG="$args_log" \
    FAKE_STAGE_FILE="$TMP_DIR/stage_invalid.txt" \
    LOOP_RISK_MODE="invalid" \
    bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$project" --cli codex > "$output" 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "invalid risk mode succeeded"
  grep -q "Invalid LOOP_RISK_MODE" "$output" || fail "invalid risk mode did not report preflight error"
  [[ ! -s "$args_log" ]] || fail "invalid risk mode called an agent"
}

run_case "safe" "codex"
run_case "unattended" "codex"
run_case "safe" "gemini"
run_case "unattended" "gemini"
run_invalid_case

echo "e2e_risk_mode: PASS"
