#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export GIT_AUTHOR_NAME="Loop Agent Test"
export GIT_AUTHOR_EMAIL="loop-agent-test@example.com"
export GIT_COMMITTER_NAME="Loop Agent Test"
export GIT_COMMITTER_EMAIL="loop-agent-test@example.com"

make_fake_bin() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/envsubst" <<'SH'
#!/usr/bin/env bash
python -c '
import os
import re
import sys

text = sys.stdin.read()
pattern = re.compile(r"\$(\w+)|\$\{([^}]+)\}")

def repl(match):
    name = match.group(1) or match.group(2)
    return os.environ.get(name, "")

sys.stdout.write(pattern.sub(repl, text))
' "$@"
SH
  chmod +x "$bin/envsubst"

  cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "exec" ]]; then
  shift
fi
prompt="$(cat)"

if grep -qi "Impl Critic" <<<"$prompt"; then
  cat <<'OUT'
# Impl Critique

## Notes
none

VERDICT: PASS
OUT
elif grep -qi "Implementer" <<<"$prompt"; then
  printf 'done\n' > done.txt
  cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1.1: Write done file - created done.txt

## Completion criteria status
- [x] verify: `test -f done.txt`

VERDICT: PASS
OUT
elif grep -qi "Plan Critic" <<<"$prompt"; then
  cat <<'OUT'
# Plan Critique

## Notes
none

VERDICT: PASS
OUT
else
  cat <<'OUT'
# Plan

## Tasks

### Task 1: Write done file
- File: done.txt
- What to do: Create done.txt.
- Completion criteria:
  - [ ] verify: `test -f done.txt`

VERDICT: PASS
OUT
fi
SH
  chmod +x "$bin/codex"
}

write_pass_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

## Tasks

- [ ] Task 1.1: Write done file
  - Files:
    - done.txt
  - Depends: none
  - Completion criteria:
    - verify: `test -f done.txt`
  - Fail count: 0
MD
}

write_blocked_backlog() {
  local project="$1"
  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<'MD'
# Backlog

## Tasks

- [!] Task 1.1: Blocked task
  - Files:
    - blocked.txt
  - Depends: none
  - Completion criteria:
    - verify: `test -f blocked.txt`
  - Fail count: 5
  - Last failure summary: blocked for test
MD
}

validate_pass_events() {
  local events="$1"
  python - "$events" <<'PY'
import json
import sys

path = sys.argv[1]
events = []
with open(path, encoding="utf-8") as f:
    for raw in f:
        if raw.strip():
            events.append(json.loads(raw))

types = {event.get("event") for event in events}
required = {"loop_start", "task_selected", "agent_done", "verify_result", "decision", "commit"}
missing = required - types
if missing:
    raise SystemExit(f"missing event types: {sorted(missing)}")

selected = next(event for event in events if event.get("event") == "task_selected")
if selected.get("task_id") != "Task 1.1" or selected.get("task_name") != "Write done file":
    raise SystemExit(f"bad task metadata: {selected}")
if not selected.get("evidence_rel") or not selected.get("verify_commands_path"):
    raise SystemExit(f"missing evidence or verify paths: {selected}")

verify = next(event for event in events if event.get("event") == "verify_result")
if verify.get("status") != "PASS":
    raise SystemExit(f"bad verify status: {verify}")

decisions = [event for event in events if event.get("event") == "decision" and event.get("outcome") == "PASS"]
if not decisions:
    raise SystemExit("missing PASS decision")

commit = next(event for event in events if event.get("event") == "commit")
if not commit.get("commit_hash"):
    raise SystemExit(f"missing commit hash: {commit}")
PY
}

validate_blocked_events() {
  local events="$1"
  python - "$events" <<'PY'
import json
import sys

path = sys.argv[1]
events = []
with open(path, encoding="utf-8") as f:
    for raw in f:
        if raw.strip():
            events.append(json.loads(raw))

blocked = [
    event for event in events
    if event.get("event") == "decision"
    and event.get("outcome") == "BLOCKED"
    and event.get("status") == "BLOCKED"
]
if not blocked:
    raise SystemExit(f"missing BLOCKED decision: {events}")
PY
}

FAKE_BIN="$TMP_ROOT/bin"
make_fake_bin "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/.codex"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"
export HOME="$HOME_DIR"

PASS_PROJECT="$TMP_ROOT/pass-project"
mkdir -p "$PASS_PROJECT"
write_pass_backlog "$PASS_PROJECT"
if ! bash "$ROOT/loop.sh" run --iterations 1 --project "$PASS_PROJECT" --cli codex > "$TMP_ROOT/pass.out" 2> "$TMP_ROOT/pass.err"; then
  cat "$TMP_ROOT/pass.err" >&2
  cat "$TMP_ROOT/pass.out" >&2
  exit 1
fi
validate_pass_events "$PASS_PROJECT/.loop-agent/events.jsonl"

BLOCKED_PROJECT="$TMP_ROOT/blocked-project"
mkdir -p "$BLOCKED_PROJECT"
write_blocked_backlog "$BLOCKED_PROJECT"
set +e
bash "$ROOT/loop.sh" run --iterations 1 --project "$BLOCKED_PROJECT" --cli codex > "$TMP_ROOT/blocked.out" 2> "$TMP_ROOT/blocked.err"
blocked_code=$?
set -e
if [[ "$blocked_code" -eq 0 ]]; then
  echo "blocked run unexpectedly succeeded" >&2
  exit 1
fi
validate_blocked_events "$BLOCKED_PROJECT/.loop-agent/events.jsonl"
