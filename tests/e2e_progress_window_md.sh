#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
FAKEBIN="$TMP/bin"
mkdir -p "$PROJECT/.loop-agent" "$FAKEBIN" "$TMP/home/.codex"

cat > "$TMP/home/.codex/auth.json" <<'JSON'
{}
JSON

cat > "$TMP/home/.gitconfig" <<'TXT'
[user]
	name = Loop Test
	email = loop-test@example.com
TXT

cat > "$PROJECT/.loop-agent/backlog.md" <<'MD'
# Backlog

## Tasks

- [ ] Task 99.1: Exercise Markdown progress window
  - Files:
    - app.txt
  - Depends: none
  - Completion criteria:
    - [ ] verify: `true`
  - Fail count: 1
  - Last failure summary: Impl Critic failure; verdict=FAIL; status=FAIL loop=0; evidence=.loop-agent/evidence/loop-0/impl_fail_reason.md
  - Evidence path: .loop-agent/evidence/loop-0/impl_fail_reason.md
MD

cat > "$PROJECT/.loop-agent/progress.txt" <<'TXT'
# Loop Agent Progress
Project: fake
Started: 2026-05-05 00:00:00
---

=== Loop 0: Impl FAIL ===
Time: 2026-05-05 00:00:01
Task: Task 99.1 - Exercise Markdown progress window
Impl Critic verdict: FAIL
Failure evidence: .loop-agent/evidence/loop-0/impl_fail_reason.md
Final decision: FAIL (Impl Critic verdict was FAIL)
diff --git SHOULD_NOT_APPEAR_IN_PROGRESS_WINDOW
huge verify output SHOULD_NOT_APPEAR_IN_PROGRESS_WINDOW
TXT

cat > "$PROJECT/app.txt" <<'TXT'
initial
TXT

cat > "$FAKEBIN/envsubst" <<'SH'
#!/usr/bin/env bash
tmp="$(mktemp)"
cat > "$tmp"
python - "$tmp" "$@" <<'PY'
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()
names = set(re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', ' '.join(sys.argv[2:])))
if not names:
    names = set(re.findall(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}', text))
    names = {a or b for a, b in names}

def repl(match):
    name = match.group(1) or match.group(2)
    return os.environ.get(name, match.group(0))

print(re.sub(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}', repl, text), end='')
PY
rm -f "$tmp"
SH
chmod +x "$FAKEBIN/envsubst"

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
prompt="$(cat)"
first_line="$(printf '%s\n' "$prompt" | head -n 1)"

if printf '%s' "$first_line" | grep -q 'Planner'; then
  cat <<'MD'
# Plan - Loop 1

## Current Task
- ID: Task 99.1
- Name: Exercise Markdown progress window

## Files read
- Planning documents read: `.loop-agent/backlog.md`, `.loop-agent/current_task.md`
- progress.txt: recent failure was bounded
- Code files examined: app.txt

## Goal
Update the app marker.

## Previous results
- Completed in previous loops: none
- Previous failures to address: use bounded context only

## Steps

### Step 1: Update marker
- What to do: Write the implemented marker.
- File: app.txt

## Tasks

### Task 1: Update marker
- File: app.txt
- What to do: Write the implemented marker.
- Completion criteria:
  - [ ] app.txt contains the implemented marker
  - [ ] verify: `true`
- Do not touch: files outside scope

## What is NOT yet implemented
none

## What will NOT be touched this loop
files outside scope
MD
elif printf '%s' "$first_line" | grep -q 'Plan Critic'; then
  cat <<'MD'
# Plan Review - Loop 1

## Files read
- plan.md
- Planning documents: .loop-agent/backlog.md, .loop-agent/current_task.md
- progress.txt

## Criterion 1: Verifiable completion criteria
PASS

## Criterion 2: Scope executable in one iteration
PASS

## Criterion 3: Does not repeat previous failures
PASS

## Criterion 4: Unimplemented requirements not ignored
PASS

## Notes
PASS: none

## Next Planner guidance
none needed

VERDICT: PASS
MD
elif printf '%s' "$first_line" | grep -q 'Implementer'; then
  printf 'implemented\n' > app.txt
  cat <<'MD'
# Implementation Summary - Loop 1

## Files read
- plan.md
- plan_critique.md
- app.txt

## Tasks completed
- [x] Task 1: Update marker - wrote the implemented marker

## Files changed
| File | Action | What changed |
|------|--------|--------------|
| app.txt | modified | wrote the implemented marker |

## Completion criteria status
Task 1:
- [x] app.txt contains the implemented marker
- [x] verify: `true` - passes

## Additional files needed
none

## Unrelated issues noticed (not fixed)
none
MD
else
  cat <<'MD'
# Implementation Review - Loop 1

## Files read
- plan.md
- impl_summary.md
- shell evidence files
- app.txt

## Completion criteria check

### Task 1: Update marker
- [x] app.txt contains the implemented marker: present
- [x] verify: `true`: passed

## Code quality issues
none

## Out-of-scope changes
none

## Scope expansion needed
none

## Notes
none

## Next Planner guidance
none needed

VERDICT: PASS
MD
fi
SH
chmod +x "$FAKEBIN/codex"

PATH="$FAKEBIN:$PATH" HOME="$TMP/home" COMMIT_ON_PASS=0 bash "$ROOT/loop.sh" run --iterations 1 --project "$PROJECT" --cli codex >"$TMP/loop.out" 2>&1 || {
  cat "$TMP/loop.out"
  cat "$PROJECT/.loop-agent/evidence/loop-1/verify_commands.txt" 2>/dev/null || true
  cat "$PROJECT/.loop-agent/evidence/loop-1/verify_results.md" 2>/dev/null || true
  exit 1
}

WINDOW="$PROJECT/.loop-agent/progress_window.md"
PROGRESS="$PROJECT/.loop-agent/progress.txt"

test -f "$WINDOW"
test -f "$PROGRESS"
test ! -f "$PROJECT/.loop-agent/progress_window.txt"

grep -q '# Progress Window' "$WINDOW"
grep -q 'Task ID: Task 99.1' "$WINDOW"
grep -q 'Task Name: Exercise Markdown progress window' "$WINDOW"
grep -q 'Fail count: 1' "$WINDOW"
grep -q 'Last verdict: FAIL' "$WINDOW"
grep -q 'Last failed stage: Impl Critic' "$WINDOW"
grep -q 'Last failure summary:' "$WINDOW"
grep -q 'Evidence path: .loop-agent/evidence/loop-0/impl_fail_reason.md' "$WINDOW"
grep -q 'Next-attempt guidance:' "$WINDOW"
grep -q '## Hard Constraints' "$WINDOW"
grep -q 'Treat this file as bounded context, not as source of truth.' "$WINDOW"
grep -q 'Do not pull full diffs, full logs, or huge verify output' "$WINDOW"
grep -q '## Recent Loop Summaries' "$WINDOW"
grep -q 'Loop 1: PASS' "$WINDOW"
! grep -q 'SHOULD_NOT_APPEAR_IN_PROGRESS_WINDOW' "$WINDOW"

bytes="$(wc -c < "$WINDOW" | tr -d ' ')"
test "$bytes" -lt 20000

grep -q 'progress_window.md' "$ROOT/agents/planner.md"
grep -q 'progress_window.md' "$ROOT/agents/implementer.md"
grep -q 'progress_window.md' "$ROOT/agents/plan_critic.md"
grep -q 'not a source of truth' "$ROOT/agents/plan_critic.md"
grep -q 'progress_window.md' "$ROOT/agents/impl_critic.md"
grep -q 'not source of truth' "$ROOT/agents/impl_critic.md"

grep -q 'progress_window.md' "$PROJECT/.loop-agent/planner_rendered.md"
! grep -q 'progress_window.txt' "$PROJECT/.loop-agent/planner_rendered.md"

grep -q 'implemented' "$PROJECT/app.txt"
