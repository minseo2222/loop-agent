#!/usr/bin/env bash

check_verdict() {
  local file="$1"
  awk '
    BEGIN {
      valid_count = 0
      malformed = 0
      trailing_after_valid = 0
      after_valid = 0
      last_nonempty = ""
    }
    {
      sub(/\r$/, "", $0)
      line = $0
      if (line ~ /^VERDICT: (PASS|FAIL|BLOCKED|SCOPE_EXPAND|SPLIT_TASK|DEPENDENCY_INSERT)$/) {
        valid_count++
        after_valid = 1
        last_nonempty = line
        next
      }
      if (line ~ /^VERDICT:/) {
        malformed = 1
        after_valid = 0
        if (line ~ /[^[:space:]]/) {
          last_nonempty = line
        }
        next
      }
      if (line ~ /[^[:space:]]/) {
        if (after_valid) {
          trailing_after_valid = 1
        }
        after_valid = 0
        last_nonempty = line
      }
    }
    END {
      if (malformed || valid_count > 1 || trailing_after_valid) {
        print "MALFORMED"
      } else if (valid_count == 0) {
        print "UNKNOWN"
      } else if (last_nonempty ~ /^VERDICT: (PASS|FAIL|BLOCKED|SCOPE_EXPAND|SPLIT_TASK|DEPENDENCY_INSERT)$/) {
        sub(/^VERDICT: /, "", last_nonempty)
        print last_nonempty
      } else {
        print "MALFORMED"
      }
    }
  ' "$file" 2>/dev/null || echo "UNKNOWN"
}

decision_is_invalid_verdict() {
  local verdict="$1"
  [[ "$verdict" == "UNKNOWN" || "$verdict" == "MALFORMED" ]]
}

decision_is_proposal_verdict() {
  local verdict="$1"
  [[ "$verdict" == "SCOPE_EXPAND" || "$verdict" == "SPLIT_TASK" || "$verdict" == "DEPENDENCY_INSERT" ]]
}

decision_extract_block_reason() {
  local critique_file="$1"
  local default_reason="$2"
  local reason

  reason="$(awk '
    BEGIN{found=0}
    /^## Notes/ {found=1; next}
    found && /^## / {exit}
    found && $0 !~ /^[[:space:]]*$/ {
      print
      exit
    }
  ' "$critique_file" | tr -d '\r')"
  if [[ -z "$reason" || "$reason" == "none" ]]; then
    reason="$(awk '
      $0 !~ /^[[:space:]]*$/ && $0 !~ /^#/ && $0 !~ /^VERDICT:/ {
        print
        exit
      }
    ' "$critique_file" | tr -d '\r')"
  fi
  reason="$(printf '%s' "$reason" | sed -E 's/^[[:space:]]*[-*][[:space:]]*//; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-240)"
  if [[ -z "$reason" ]]; then
    reason="$default_reason"
  fi
  printf '%s\n' "$reason"
}
