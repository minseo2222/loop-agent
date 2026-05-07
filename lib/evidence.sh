write_normalized_changed_path() {
  local path="$1"
  local project_out="$2"
  local state_out="$3"

  path="${path#./}"
  [[ -z "$path" ]] && return 0

  case "$path" in
    .loop-agent|.loop-agent/*)
      printf '%s\n' "$path" >> "$state_out"
      ;;
    *)
      printf '%s\n' "$path" >> "$project_out"
      ;;
  esac
}

normalize_changed_files() {
  local raw_changed="$1"
  local project_out="$2"
  local state_out="$3"
  local record status path path2 x y

  : > "$project_out"
  : > "$state_out"

  while IFS= read -r -d '' record; do
    [[ -z "$record" ]] && continue

    status="${record:0:2}"
    path="${record:3}"
    x="${status:0:1}"
    y="${status:1:1}"

    if [[ "$x" == "R" || "$y" == "R" || "$x" == "C" || "$y" == "C" ]]; then
      path2=""
      IFS= read -r -d '' path2 || true
      write_normalized_changed_path "$path2" "$project_out" "$state_out"
    fi

    write_normalized_changed_path "$path" "$project_out" "$state_out"
  done < "$raw_changed"
}

capture_git_evidence() {
  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  mkdir -p "$EVIDENCE_DIR"
  local exit_codes="$EVIDENCE_DIR/git_exit_codes.txt"
  local raw_changed="$EVIDENCE_DIR/changed_files.raw"
  local code

  : > "$exit_codes"

  if git -C "$PROJECT_DIR" status --short --untracked-files=all > "$EVIDENCE_DIR/status.txt" 2>"$EVIDENCE_DIR/status.stderr"; then
    code=0
  else
    code=$?
  fi
  echo "status=$code" >> "$exit_codes"

  if git -C "$PROJECT_DIR" status --porcelain=v1 -z --untracked-files=all > "$raw_changed" 2>"$EVIDENCE_DIR/changed_files.stderr"; then
    code=0
    normalize_changed_files "$raw_changed" "$EVIDENCE_DIR/changed_files.txt" "$EVIDENCE_DIR/changed_state_files.txt"
  else
    code=$?
    : > "$EVIDENCE_DIR/changed_files.txt"
    : > "$EVIDENCE_DIR/changed_state_files.txt"
  fi
  echo "changed_files=$code" >> "$exit_codes"

  if git -C "$PROJECT_DIR" diff --stat HEAD -- > "$EVIDENCE_DIR/diff_stat.txt" 2>"$EVIDENCE_DIR/diff_stat.stderr"; then
    code=0
  else
    code=$?
  fi
  echo "diff_stat=$code" >> "$exit_codes"

  if git -C "$PROJECT_DIR" diff HEAD -- > "$EVIDENCE_DIR/diff.patch" 2>"$EVIDENCE_DIR/diff.stderr"; then
    code=0
  else
    code=$?
  fi
  echo "diff=$code" >> "$exit_codes"
}

evidence_referenced_dirs() {
  [[ -f "$BACKLOG" ]] || return 0

  sed -nE 's|.*(\.loop-agent/evidence/loop-[0-9]+(__[^/[:space:]]+)?)(/[^[:space:]]*)?.*|\1|p' "$BACKLOG" 2>/dev/null \
    | sort -u \
    | while IFS= read -r rel_dir; do
        [[ -n "$rel_dir" ]] || continue
        if [[ -d "$PROJECT_DIR/$rel_dir" ]]; then
          (cd "$PROJECT_DIR/$rel_dir" && pwd)
        fi
      done
}

archive_or_compact_evidence_dir() {
  local dir="$1"
  local base archive tmp compact

  case "$dir" in
    "$EVIDENCE_ROOT"/loop-*) ;;
    *) return 1 ;;
  esac

  [[ -d "$dir" ]] || return 0
  base="$(basename "$dir")"
  [[ "$base" =~ ^loop-[0-9]+(__.*)?$ ]] || return 1

  archive="$EVIDENCE_ROOT/${base}.tar.gz"
  tmp="$archive.tmp.$$"
  compact="$EVIDENCE_ROOT/${base}.compacted.md"

  if tar -czf "$tmp" -C "$EVIDENCE_ROOT" "$base" 2>/dev/null; then
    mv -f "$tmp" "$archive"
    rm -rf -- "$dir"
    info "Evidence archived: .loop-agent/evidence/${base}.tar.gz"
    return 0
  fi

  rm -f "$tmp"
  {
    echo "# Compacted evidence"
    echo ""
    echo "Original directory: .loop-agent/evidence/$base/"
    echo "Compacted at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "## Files"
    find "$dir" -type f 2>/dev/null | sort | sed "s|^$dir/|- |"
  } > "$compact"
  rm -rf -- "$dir"
  info "Evidence compacted: .loop-agent/evidence/${base}.compacted.md"
}

apply_evidence_retention() {
  [[ "${LOOP_EVIDENCE_KEEP_RUNS:-10}" != "0" ]] || return 0
  [[ -n "${EVIDENCE_ROOT:-}" ]] && [[ -d "$EVIDENCE_ROOT" ]] || return 0
  [[ -n "${EVIDENCE_DIR:-}" ]] && [[ -d "$EVIDENCE_DIR" ]] || return 0

  local -a dirs=()
  local -a keep_dirs=()
  local -a protected_dirs=()
  local dir base current_dir i

  # Collect candidate evidence dirs sorted newest-first by mtime so multiple
  # runs that each restart the loop counter at 1 don't trample one another:
  # the new format is `loop-N__<task>__<run-ts>`, but legacy bare `loop-N`
  # dirs are still recognized for back-compat.
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    [[ "$base" =~ ^loop-[0-9]+(__.*)?$ ]] || continue
    dirs+=("$dir")
  done < <(ls -1td -- "$EVIDENCE_ROOT"/loop-*/ 2>/dev/null | sed 's|/$||')

  [[ ${#dirs[@]} -gt 0 ]] || return 0

  # Newest N stay (front of mtime-sorted list)
  for ((i=0; i<${#dirs[@]} && i<LOOP_EVIDENCE_KEEP_RUNS; i++)); do
    keep_dirs+=("${dirs[$i]}")
  done

  current_dir="$(cd "$EVIDENCE_DIR" && pwd)"
  protected_dirs+=("$current_dir")
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && protected_dirs+=("$dir")
  done < <(evidence_referenced_dirs)

  for dir in "${dirs[@]}"; do
    if path_in_list "$dir" "${keep_dirs[@]}" || path_in_list "$dir" "${protected_dirs[@]}"; then
      continue
    fi
    archive_or_compact_evidence_dir "$dir" || warn "Evidence retention skipped: $dir"
  done
}
