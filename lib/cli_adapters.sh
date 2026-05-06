#!/usr/bin/env bash

GEMINI_MODEL="${LOOP_GEMINI_MODEL:-gemini-3.1-pro-preview}"
if [[ -n "${LOOP_GEMINI_FLAGS+x}" ]]; then
  GEMINI_FLAGS="$LOOP_GEMINI_FLAGS"
elif [[ "${LOOP_RISK_MODE:-unattended}" == "unattended" ]]; then
  GEMINI_FLAGS="--yolo"
else
  GEMINI_FLAGS=""
fi
GEMINI_MODEL_FLAG="${LOOP_GEMINI_MODEL_FLAG:---model}"

run_codex_agent() {
  local project_dir="$1"
  local agent_file="$2"
  local out_file="$3"
  local log_file="$4"
  local model="${5:-${CODEX_MODEL:-gpt-5.5}}"
  local reasoning="${6:-medium}"
  local -a codex_args=()

  if [[ "${LOOP_RISK_MODE:-unattended}" == "unattended" ]]; then
    codex_args+=(--dangerously-bypass-approvals-and-sandbox)
  fi
  codex_args+=(-m "$model" -c "model_reasoning_effort=\"$reasoning\"" -)

  ( cd "$project_dir" && codex exec \
    "${codex_args[@]}" < "$agent_file" \
    > "$out_file" \
    2>> "$log_file" )
}

run_gemini_agent() {
  local project_dir="$1"
  local agent_file="$2"
  local out_file="$3"
  local log_file="$4"

  if [[ "${LOOP_GEMINI_USE_PROMPT_ARG:-0}" == "1" ]]; then
    ( cd "$project_dir" && gemini \
      $GEMINI_FLAGS \
      $GEMINI_MODEL_FLAG "$GEMINI_MODEL" \
      -p "$(cat "$agent_file")" \
      > "$out_file" \
      2>> "$log_file" )
  else
    ( cd "$project_dir" && gemini \
      $GEMINI_FLAGS \
      $GEMINI_MODEL_FLAG "$GEMINI_MODEL" \
      < "$agent_file" \
      > "$out_file" \
      2>> "$log_file" )
  fi
}
