#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LoopDex · run.sh
#
#  Usage:
#    ./run.sh [options] <doc-path>
#
#  Deprecated:
#    Use ./loop.sh init and ./loop.sh run for new work.
#    run.sh is retained only for legacy document-driven workflows.
#
#  Options:
#    -n, --loops <N>       iterations (default: 3)
#    -t, --tool  <tool>    AI tool: claude | codex (default: codex)
#    -h, --help            help
#
#  Examples:
#    ./run.sh -n 5 -t codex  docs/feature.md
#    ./run.sh -n 3 -t claude docs/feature.md
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$SCRIPT_DIR/prompts"
STATE="$SCRIPT_DIR/state"
LOGS_DIR="$SCRIPT_DIR/logs"

# ── Color output ──────────────────────────────────────────────
BOLD="\033[1m"; RESET="\033[0m"
CYAN="\033[36m"; GREEN="\033[32m"; YELLOW="\033[33m"
RED="\033[31m"; GRAY="\033[90m"; MAGENTA="\033[35m"

banner() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║  $1${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}\n"
}
phase()  { echo -e "\n${BOLD}${MAGENTA}┌─ $1 ─┐${RESET}"; }
step()   { echo -e "${BOLD}${YELLOW}  ▶ $1${RESET}"; }
ok()     { echo -e "${GREEN}  ✓ $1${RESET}"; }
fail()   { echo -e "${RED}  ✗ $1${RESET}"; }
info()   { echo -e "${GRAY}    $1${RESET}"; }
warn()   { echo -e "${YELLOW}  ⚠ $1${RESET}"; }

# ── Argument parsing ──────────────────────────────────────────
MAX_LOOPS=3
AI_TOOL="codex"
DOC_PATH=""

usage() {
  echo "Deprecated: run.sh is a legacy compatibility entrypoint."
  echo "Use ./loop.sh init and ./loop.sh run for new work."
  echo ""
  echo "Usage: ./run.sh [options] <doc-path>"
  echo ""
  echo "Options:"
  echo "  -n, --loops <N>    iterations (default: 3)"
  echo "  -t, --tool  <t>    AI tool: claude | codex (default: codex)"
  echo "  -h, --help         show this help"
  echo ""
  echo "Examples:"
  echo "  ./run.sh -n 5 -t codex  docs/feature.md"
  echo "  ./run.sh -n 3 -t claude docs/feature.md"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--loops) MAX_LOOPS="$2"; shift 2 ;;
    -t|--tool)  AI_TOOL="$2";   shift 2 ;;
    -h|--help)  usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)  DOC_PATH="$1"; shift ;;
  esac
done

warn "Deprecated: run.sh is retained only for legacy document-driven workflows."
warn "Use ./loop.sh init and ./loop.sh run for new work."

# ── Validation ────────────────────────────────────────────────
if [[ -z "$DOC_PATH" ]]; then
  fail "Doc path is required."
  usage
fi

if [[ ! -f "$DOC_PATH" ]]; then
  fail "File not found: $DOC_PATH"
  exit 1
fi

if ! [[ "$MAX_LOOPS" =~ ^[0-9]+$ ]] || [[ "$MAX_LOOPS" -lt 1 ]]; then
  fail "Iterations must be a positive integer."
  exit 1
fi

if [[ "$AI_TOOL" != "claude" && "$AI_TOOL" != "codex" ]]; then
  fail "Supported tools: claude | codex"
  exit 1
fi

# ── Check CLI availability ────────────────────────────────────
case "$AI_TOOL" in
  codex)
    if ! command -v codex &>/dev/null; then
      fail "Codex CLI not found."
      echo "  Install: npm install -g @openai/codex"
      exit 1
    fi
    ;;
  claude)
    if ! command -v claude &>/dev/null; then
      fail "Claude Code CLI not found."
      echo "  Install: npm install -g @anthropic-ai/claude-code"
      exit 1
    fi
    ;;
esac

# ── Path / session initialization ─────────────────────────────
DOC_ABS="$(cd "$(dirname "$DOC_PATH")" && pwd)/$(basename "$DOC_PATH")"
DOC_CONTENT="$(cat "$DOC_ABS")"
SESSION_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOGS_DIR/session_${SESSION_ID}.log"
REPORT_FILE="$LOGS_DIR/report_${SESSION_ID}.md"

mkdir -p "$LOGS_DIR" "$STATE"
> "$LOG_FILE"
> "$STATE/progress.txt"

cat > "$STATE/session.json" <<JSON
{
  "session_id": "$SESSION_ID",
  "tool": "$AI_TOOL",
  "doc": "$DOC_ABS",
  "max_loops": $MAX_LOOPS,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# ── Report header ─────────────────────────────────────────────
cat > "$REPORT_FILE" <<MD
# Loop Agent Run Report

| Item | Value |
|------|-------|
| Session ID | \`$SESSION_ID\` |
| AI tool | $AI_TOOL |
| Doc | \`$DOC_ABS\` |
| Max iterations | ${MAX_LOOPS} |
| Started | $(date '+%Y-%m-%d %H:%M:%S') |

---

MD

# ── AI execution function (per-tool dispatch) ─────────────────
# Each agent call is an independent process → fully isolated context
run_ai() {
  local prompt="$1"
  local outfile="$2"

  case "$AI_TOOL" in
    codex)
      # Codex CLI: --quiet = output only, -f - = read prompt from stdin
      echo "$prompt" | codex --quiet -f - > "$outfile" 2>>"$LOG_FILE"
      ;;
    claude)
      # Claude Code: --print = non-interactive mode
      claude --print "$prompt" > "$outfile" 2>>"$LOG_FILE"
      ;;
  esac
}

# ── Helpers: extract score/verdict ───────────────────────────
extract_score() {
  local file="$1"
  grep -oE '"?score"?\s*:\s*[0-9]+' "$file" 2>/dev/null \
    | grep -oE '[0-9]+' | tail -1 || echo "0"
}

extract_verdict() {
  local file="$1"
  grep -oiE '(PASS|FAIL|APPROVE|REJECT)' "$file" 2>/dev/null \
    | tail -1 | tr '[:lower:]' '[:upper:]' || echo "UNKNOWN"
}

# ── Prompt rendering ──────────────────────────────────────────
render_prompt() {
  local template_file="$1"
  local content
  content="$(cat "$template_file")"

  # Variable substitution
  content="${content//\{\{DOC_CONTENT\}\}/$DOC_CONTENT}"
  content="${content//\{\{LOOP_NUM\}\}/$CURRENT_LOOP}"
  content="${content//\{\{MAX_LOOPS\}\}/$MAX_LOOPS}"
  content="${content//\{\{PROGRESS\}\}/$PROGRESS}"
  content="${content//\{\{PLAN\}\}/$PLAN}"
  content="${content//\{\{PLAN_CRITIQUE\}\}/$PLAN_CRITIQUE}"
  content="${content//\{\{IMPL_RESULT\}\}/$IMPL_RESULT}"

  echo "$content"
}

# ═══════════════════════════════════════════════════════════════
#  Main loop
# ═══════════════════════════════════════════════════════════════
banner "Loop Agent  ·  tool: $AI_TOOL  ·  max ${MAX_LOOPS} loops"
echo -e "  Doc: ${BOLD}$DOC_ABS${RESET}"
echo -e "  Log: ${GRAY}$LOG_FILE${RESET}"
echo ""

LOOP_RESULTS=()   # per-loop result summary (for report)

for (( CURRENT_LOOP=1; CURRENT_LOOP<=MAX_LOOPS; CURRENT_LOOP++ )); do

  banner "Loop $CURRENT_LOOP / $MAX_LOOPS"
  LOOP_START_TIME=$(date +%s)
  LOOP_STATUS="completed"
  LOOP_NOTE=""

  # Load prior loop progress notes
  PROGRESS=""
  [[ -s "$STATE/progress.txt" ]] && PROGRESS="$(cat "$STATE/progress.txt")"

  # ──────────────────────────────────────────────────────────
  # PHASE 1: PLANNER  (independent context)
  # ──────────────────────────────────────────────────────────
  phase "Phase 1: Planner"
  step "Analyzing doc and generating task plan..."

  PLAN=""
  PLANNER_PROMPT="$(render_prompt "$PROMPTS/planner.md")"

  if run_ai "$PLANNER_PROMPT" "$STATE/plan.md"; then
    PLAN="$(cat "$STATE/plan.md")"
    ok "Plan generated ($(wc -l < "$STATE/plan.md") lines)"
    info "→ $STATE/plan.md"
  else
    fail "Planner failed → skipping this loop"
    LOOP_STATUS="planner_failed"
    LOOP_NOTE="Planner agent error"
    LOOP_RESULTS+=("Loop $CURRENT_LOOP: ❌ Planner failed")
    echo "" >> "$REPORT_FILE"
    echo "## Loop $CURRENT_LOOP — ❌ Planner failed" >> "$REPORT_FILE"
    continue
  fi

  # ──────────────────────────────────────────────────────────
  # PHASE 2: PLAN CRITIC  (independent context)
  # ──────────────────────────────────────────────────────────
  phase "Phase 2: Plan Critic"
  step "Reviewing plan independently..."

  PLAN_CRITIQUE=""
  PLAN_CRITIC_PROMPT="$(render_prompt "$PROMPTS/plan_critic.md")"

  if run_ai "$PLAN_CRITIC_PROMPT" "$STATE/plan_critique.md"; then
    PLAN_CRITIQUE="$(cat "$STATE/plan_critique.md")"
    PLAN_SCORE="$(extract_score "$STATE/plan_critique.md")"
    PLAN_VERDICT="$(extract_verdict "$STATE/plan_critique.md")"
    ok "Plan review done  (score: ${PLAN_SCORE}/10  verdict: ${PLAN_VERDICT})"
  else
    warn "Plan Critic failed → proceeding with plan as-is"
    PLAN_SCORE="5"
    PLAN_VERDICT="PASS"
    PLAN_CRITIQUE="(review failed - default pass)"
  fi

  # If score < 6, reject plan (skip this loop, replan next loop)
  if [[ "$PLAN_SCORE" -lt 6 ]] || [[ "$PLAN_VERDICT" == "FAIL" || "$PLAN_VERDICT" == "REJECT" ]]; then
    fail "Plan review failed (score: $PLAN_SCORE/10) → skipping this loop, replanning next loop"

    # Record failure reason in progress.txt (for next loop's Planner)
    {
      echo "=== Loop $CURRENT_LOOP plan review failed ==="
      echo "Score: $PLAN_SCORE/10"
      echo "Review:"
      echo "$PLAN_CRITIQUE" | head -20
      echo ""
    } >> "$STATE/progress.txt"

    LOOP_STATUS="plan_rejected"
    LOOP_NOTE="Plan score ${PLAN_SCORE}/10 — replanning needed"
    LOOP_RESULTS+=("Loop $CURRENT_LOOP: ⚠️  Plan review failed (${PLAN_SCORE}/10)")

    {
      echo ""
      echo "## Loop $CURRENT_LOOP — ⚠️ Plan review failed"
      echo ""
      echo "**Score**: ${PLAN_SCORE}/10  **Verdict**: ${PLAN_VERDICT}"
      echo ""
      echo "### Review"
      echo '```'
      echo "$PLAN_CRITIQUE" | head -30
      echo '```'
      echo ""
    } >> "$REPORT_FILE"
    continue
  fi

  ok "Plan review passed (${PLAN_SCORE}/10) → proceeding to implementation"

  # ──────────────────────────────────────────────────────────
  # PHASE 3: IMPLEMENTER  (independent context)
  # ──────────────────────────────────────────────────────────
  phase "Phase 3: Implementer"
  step "Generating code/files based on plan..."

  IMPL_RESULT=""
  IMPL_PROMPT="$(render_prompt "$PROMPTS/implementer.md")"

  if run_ai "$IMPL_PROMPT" "$STATE/impl_result.md"; then
    IMPL_RESULT="$(cat "$STATE/impl_result.md")"
    ok "Implementation done ($(wc -l < "$STATE/impl_result.md") lines)"
    info "→ $STATE/impl_result.md"
  else
    fail "Implementer failed → skipping review, going to next loop"
    LOOP_STATUS="impl_failed"
    LOOP_NOTE="Implementer agent error"
    LOOP_RESULTS+=("Loop $CURRENT_LOOP: ❌ Implementation failed")
    {
      echo ""
      echo "## Loop $CURRENT_LOOP — ❌ Implementation failed"
      echo ""
    } >> "$REPORT_FILE"
    continue
  fi

  # ──────────────────────────────────────────────────────────
  # PHASE 4: IMPL CRITIC  (independent context)
  # ──────────────────────────────────────────────────────────
  phase "Phase 4: Impl Critic"
  step "Reviewing implementation independently..."

  IMPL_CRITIC_PROMPT="$(render_prompt "$PROMPTS/impl_critic.md")"

  if run_ai "$IMPL_CRITIC_PROMPT" "$STATE/impl_critique.md"; then
    IMPL_SCORE="$(extract_score "$STATE/impl_critique.md")"
    IMPL_VERDICT="$(extract_verdict "$STATE/impl_critique.md")"
    ok "Implementation review done  (score: ${IMPL_SCORE}/10  verdict: ${IMPL_VERDICT})"
  else
    warn "Impl Critic failed → applying implementation as-is"
    IMPL_SCORE="7"
    IMPL_VERDICT="PASS"
  fi

  # ──────────────────────────────────────────────────────────
  # PHASE 5: Apply or rollback
  # ──────────────────────────────────────────────────────────
  phase "Phase 5: Apply or discard"

  if [[ "$IMPL_SCORE" -ge 7 ]] && [[ "$IMPL_VERDICT" != "FAIL" && "$IMPL_VERDICT" != "REJECT" ]]; then
    ok "Implementation review passed (${IMPL_SCORE}/10) → applying result"

    # Save impl_result.md per-loop in the outputs directory
    LOOP_OUTPUT="$LOGS_DIR/loop_${CURRENT_LOOP}_output.md"
    cp "$STATE/impl_result.md" "$LOOP_OUTPUT"
    ok "Result saved → $LOOP_OUTPUT"

    LOOP_STATUS="applied"
    LOOP_NOTE="Implementation review passed (${IMPL_SCORE}/10) — applied"
    LOOP_RESULTS+=("Loop $CURRENT_LOOP: ✅ Applied (${IMPL_SCORE}/10)")

    # Record success in progress.txt (passed to next loop's Planner)
    {
      echo "=== Loop $CURRENT_LOOP complete ==="
      echo "Implementation review score: $IMPL_SCORE/10"
      echo "Key tasks:"
      grep -E "^(##|###|-|\*)" "$STATE/plan.md" | head -15 || true
      echo ""
    } >> "$STATE/progress.txt"

  else
    fail "Implementation review failed (${IMPL_SCORE}/10) → discarding, retry next loop"

    LOOP_STATUS="impl_rejected"
    LOOP_NOTE="Implementation score ${IMPL_SCORE}/10 — reimplementation needed"
    LOOP_RESULTS+=("Loop $CURRENT_LOOP: ⚠️  Implementation review failed (${IMPL_SCORE}/10)")

    # Record failure reason in progress.txt
    {
      echo "=== Loop $CURRENT_LOOP implementation failed ==="
      echo "Implementation review score: $IMPL_SCORE/10"
      echo "Areas for improvement:"
      cat "$STATE/impl_critique.md" | head -20
      echo ""
    } >> "$STATE/progress.txt"
  fi

  # ── Loop elapsed time ─────────────────────────────────────
  LOOP_END_TIME=$(date +%s)
  LOOP_ELAPSED=$(( LOOP_END_TIME - LOOP_START_TIME ))

  # ── Per-loop report section ────────────────────────────────
  {
    echo ""
    echo "## Loop $CURRENT_LOOP — $(echo "$LOOP_STATUS" | tr '_' ' ')"
    echo ""
    echo "| Item | Value |"
    echo "|------|-------|"
    echo "| Elapsed | ${LOOP_ELAPSED}s |"
    echo "| Plan score | ${PLAN_SCORE}/10 |"
    if [[ "$LOOP_STATUS" != "plan_rejected" ]]; then
      echo "| Implementation score | ${IMPL_SCORE}/10 |"
    fi
    echo "| Final status | $LOOP_NOTE |"
    echo ""
    echo "### Plan summary"
    echo '```'
    head -30 "$STATE/plan.md" 2>/dev/null || echo "(none)"
    echo '```'
    echo ""
    if [[ -f "$STATE/impl_result.md" && "$LOOP_STATUS" != "plan_rejected" ]]; then
      echo "### Implementation summary"
      echo '```'
      head -30 "$STATE/impl_result.md" 2>/dev/null || echo "(none)"
      echo '```'
    fi
    echo ""
    echo "---"
  } >> "$REPORT_FILE"

  echo ""

done

# ═══════════════════════════════════════════════════════════════
#  Final summary report
# ═══════════════════════════════════════════════════════════════
{
  echo ""
  echo "## Summary"
  echo ""
  echo "| Loop | Result |"
  echo "|------|--------|"
  for summary in "${LOOP_RESULTS[@]}"; do
    echo "| $summary |"
  done
  echo ""
  echo "**Finished**: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
} >> "$REPORT_FILE"

banner "Run complete"
echo -e "  ${BOLD}Per-loop results${RESET}"
for summary in "${LOOP_RESULTS[@]}"; do
  echo -e "    $summary"
done
echo ""
echo -e "  ${BOLD}Report${RESET}: ${CYAN}$REPORT_FILE${RESET}"
echo -e "  ${BOLD}Log${RESET}:    ${GRAY}$LOG_FILE${RESET}"
echo ""
