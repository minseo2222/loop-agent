#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PROJECT_DIR="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
FAKE_STATE="$TMP_DIR/fake-state"
PROBE_FILE="$TMP_DIR/transaction_probes.jsonl"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/.loop-agent" "$FAKE_BIN" "$FAKE_STATE"

cat > "$PROJECT_DIR/.loop-agent/backlog.md" <<'MD'
# Backlog

## Tasks

- [ ] Task 1: Transaction state test
  - Depends: none
  - Fail count: 0
  - Files:
    - app.txt
  - Completion criteria:
    - [ ] app.txt is created.
    - [ ] verify: `grep -q done app.txt`
MD

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@example.com"
git -C "$PROJECT_DIR" config user.name "Test User"
printf 'initial\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m "initial"

mkdir -p "$TMP_DIR/home/.codex"
printf '{}\n' > "$TMP_DIR/home/.codex/auth.json"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
if printf '%s' "$prompt" | grep -q 'current_transaction.json'; then
  echo "transaction file leaked into prompt" >&2
  exit 42
fi

count_file="$FAKE_CLI_STATE/count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

python - "$TRANSACTION_PROBE_FILE" "$count" <<'PY'
import json
import os
import sys

probe_file = sys.argv[1]
call = int(sys.argv[2])
path = os.path.join(os.getcwd(), ".loop-agent", "current_transaction.json")
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

required = ["loop", "task_id", "stage", "snapshot_commit", "evidence_dir"]
missing = [key for key in required if key not in data]
if missing:
    raise SystemExit("missing transaction fields: " + ",".join(missing))
if data["loop"] != 1:
    raise SystemExit("unexpected loop")
if data["task_id"] != "Task 1":
    raise SystemExit("unexpected task id")
if not data["evidence_dir"]:
    raise SystemExit("missing evidence dir")
if data.get("complete") is not False:
    raise SystemExit("transaction completed too early")

with open(probe_file, "a", encoding="utf-8") as out:
    out.write(json.dumps({
        "call": call,
        "stage": data["stage"],
        "snapshot_commit": data["snapshot_commit"],
        "evidence_dir": data["evidence_dir"],
    }) + "\n")
PY

case "$count" in
  1)
    cat <<'OUT'
# Plan

## Goal
Create app.txt for the transaction test.

## Tasks

### Task 1: Create app.txt
- File: app.txt
- What to do: Write the required content.
- Completion criteria:
  - [ ] app.txt is created.
  - [ ] verify: `grep -q done app.txt`
OUT
    ;;
  2)
    cat <<'OUT'
# Plan Review

## Notes
PASS: none

VERDICT: PASS
OUT
    ;;
  3)
    printf 'done\n' > app.txt
    cat <<'OUT'
# Implementation Summary

## Tasks completed
- [x] Task 1: Create app.txt - wrote the file.

## Completion criteria status
Task 1:
- [x] app.txt is created.
- [x] verify: `grep -q done app.txt`
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
    echo "unexpected fake codex call: $count" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKE_BIN/codex"

if ! PATH="$FAKE_BIN:$PATH" \
  HOME="$TMP_DIR/home" \
  FAKE_CLI_STATE="$FAKE_STATE" \
  TRANSACTION_PROBE_FILE="$PROBE_FILE" \
  bash "$ROOT_DIR/loop.sh" run --iterations 1 --project "$PROJECT_DIR" --cli codex > "$TMP_DIR/loop.out" 2> "$TMP_DIR/loop.err"; then
  cat "$TMP_DIR/loop.out"
  cat "$TMP_DIR/loop.err" >&2
  exit 1
fi

python - "$PROBE_FILE" "$PROJECT_DIR/.loop-agent/current_transaction.json" <<'PY'
import json
import os
import sys

probe_file = sys.argv[1]
final_path = sys.argv[2]

with open(probe_file, "r", encoding="utf-8") as f:
    probes = [json.loads(line) for line in f if line.strip()]

if len(probes) < 4:
    raise SystemExit("expected at least four transaction probes")

stages = {probe["stage"] for probe in probes}
if len(stages) < 2:
    raise SystemExit("expected at least two distinct transaction stages")

if not any(probe["snapshot_commit"] for probe in probes):
    raise SystemExit("expected a populated snapshot_commit in a probe")

if os.path.exists(final_path):
    with open(final_path, "r", encoding="utf-8") as f:
        final = json.load(f)
    if final.get("complete") is not True:
        raise SystemExit("final transaction is not complete")
    for key in ["loop", "task_id", "stage", "snapshot_commit", "evidence_dir"]:
        if key not in final:
            raise SystemExit("final transaction missing " + key)
PY

echo "PASS e2e_transaction_state"
