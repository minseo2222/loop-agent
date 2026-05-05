#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/project"
FAKE_BIN="$TMP_DIR/bin"
AI_LOG="$TMP_DIR/ai.log"

mkdir -p "$PROJECT/src" "$FAKE_BIN"
printf 'sample\n' > "$PROJECT/README.md"
printf 'content\n' > "$PROJECT/src/file.txt"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "codex invoked: $*" >> "$AI_LOG"
exit 99
SH

cat > "$FAKE_BIN/gemini" <<'SH'
#!/usr/bin/env bash
echo "gemini invoked: $*" >> "$AI_LOG"
exit 99
SH

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gemini"

snapshot_project() {
  (
    cd "$PROJECT"
    find . -mindepth 1 -print | sort | while IFS= read -r path; do
      if [[ -d "$path" ]]; then
        printf 'D %s\n' "$path"
      elif [[ -f "$path" ]]; then
        printf 'F %s %s\n' "$path" "$(cksum < "$path")"
      fi
    done
  )
}

run_reserved() {
  local command_name="$1"
  local output before after

  before="$(snapshot_project)"
  if ! output="$(PATH="$FAKE_BIN:$PATH" AI_LOG="$AI_LOG" "$ROOT/loop.sh" "$command_name" --project "$PROJECT" 2>&1)"; then
    echo "$command_name failed unexpectedly"
    echo "$output"
    exit 1
  fi
  after="$(snapshot_project)"

  if [[ "$output" != *"$command_name"* ]]; then
    echo "$command_name output did not name the command"
    echo "$output"
    exit 1
  fi

  if [[ "$output" != *"reserved"* && "$output" != *"minimal"* ]]; then
    echo "$command_name output did not say reserved or minimal"
    echo "$output"
    exit 1
  fi

  if [[ -e "$AI_LOG" ]]; then
    echo "$command_name invoked an AI CLI"
    cat "$AI_LOG"
    exit 1
  fi

  if [[ "$before" != "$after" ]]; then
    echo "$command_name modified the project"
    echo "before:"
    echo "$before"
    echo "after:"
    echo "$after"
    exit 1
  fi
}

run_reserved status
run_reserved doctor

echo "reserved subcommands e2e passed"
