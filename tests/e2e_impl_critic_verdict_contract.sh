#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

prompt="agents/impl_critic.md"

require_text() {
  local text="$1"
  if ! grep -Fq "$text" "$prompt"; then
    echo "missing required text: $text" >&2
    exit 1
  fi
}

require_text "Allowed verdicts are exactly:"
require_text "VERDICT: PASS"
require_text "VERDICT: FAIL"
require_text "VERDICT: SCOPE_EXPAND"
require_text "VERDICT: SPLIT_TASK"
require_text "The final line must be exactly one allowed verdict."
require_text "No text may appear after the verdict."
require_text 'SCOPE_EXPAND and SPLIT_TASK are proposal verdicts only; they do not mutate backlog semantic fields, edit `Files`, create child tasks, or edit dependencies in explicit run mode.'
