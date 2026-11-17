#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

readonly ADMIN_HINT='rerun the cleanup script as root yourself'
readonly USAGE='Usage: cleanup.sh [--ids <a,b,c>] [--dry-run] [--log-path <path>] [--scan-path <path>] [--rules <path>] [--help]'
readonly BYTES_PER_MB=1048576
readonly field_tab=$'\t'

rules_file="$SCRIPT_DIR/../rules/rules.json"
all_rules=""
dry_run="no"
platform=""
target=""
crit_paths=""
crit_names=""
crit_bad=""
prot_paths=""
prot_names=""
scan_json=""
free_root=""
log_path=""
skipped_ids=""
refused_items=""

list_has() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

fail_arg() {
  printf 'Invalid argument: %s\n' "$1" >&2
  exit 2
}

parse_ids() {
  local parts=()
  local seen=""
  local part
  IFS=',' read -r -a parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [ -n "$part" ] || continue
    if ! list_has "$seen" "$part"; then
      seen="$seen$part"$'\n'
      printf '%s\n' "$part"
    fi
  done
}

resolve_log_path() {
  local requested="$1"
  local default_path
  default_path="$(dirname "$2")/cleanup.log"
  local chosen="$default_path"
  if [ -n "$requested" ]; then
    if dc_is_temp_path "$requested" "$platform"; then
      printf 'Log path refused (inside Temp), using %s\n' "$default_path" >&2
    else
      chosen="$requested"
    fi
  fi
  if [ "$chosen" = "$default_path" ] && dc_is_temp_path "$chosen" "$platform"; then
    printf 'No usable log path: %s\n' "$chosen" >&2
    return 3
  fi
  if ! dc_make_private_dir "$(dirname "$chosen")"; then
    printf 'No usable log path: %s\n' "$chosen" >&2
    return 3
  fi
  printf '%s\n' "$chosen"
}

write_log_line() {
  local detail="${7//[$'\t\n']/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$6" "$detail" >>"$1"
}

free_bytes_or_zero() {
  dc_free_bytes "$1" || echo 0
}

has_link_ancestor() {
  local dir
  dir="$(dirname -- "$1")"
  while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    dc_is_under "$dir" "$HOME" || return 1
    if dc_is_under "$HOME" "$dir"; then
      return 1
    fi
    if [ -L "$dir" ]; then
      return 0
    fi
    dir="$(dirname -- "$dir")"
  done
  return 1
}

tool_in_scope() {
  [ "$(dc_match_entry_count "$1" "$platform")" -eq 0 ] || [ -n "$(dc_rule_paths "$1" "$platform" "$target")" ]
}

is_refused_root() {
  [ -L "$1" ] || has_link_ancestor "$1" || dc_is_protected_target "$1" "$crit_paths" "$crit_names"
}

step_decision() {
  local rule="$2"
  if [ -z "$rule" ]; then
    printf 'refused\tunknown id\n'
    return 0
  fi
  if [ "$(jq -r '.tier' <<<"$rule")" = "critical" ]; then
    printf 'refused\tcritical\n'
    return 0
  fi
  if [ "$(jq -r '.action == null' <<<"$rule")" = "true" ]; then
    printf 'refused\tno action\n'
    return 0
  fi
  if [ "$(jq -r --arg p "$platform" '.platforms | index($p) == null' <<<"$rule")" = "true" ]; then
    printf 'not-applicable\tother OS\n'
    return 0
  fi
  if [ -n "$crit_bad" ]; then
    printf 'refused\tinvalid critical path %s\n' "${crit_bad%%$'\n'*}"
    return 0
  fi
  if [ "$(jq -r '.needsAdmin == true' <<<"$rule")" = "true" ] && ! dc_is_elevated; then
    printf 'skipped\tneeds admin: %s\n' "$ADMIN_HINT"
    return 0
  fi
  if [ "$(jq -r '.action.type' <<<"$rule")" = "tool" ]; then
    local cmd
    cmd="$(jq -r '.action.command' <<<"$rule")"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'not-applicable\ttool not found: %s\n' "$cmd"
      return 0
    fi
    if [ -n "$target" ] && ! tool_in_scope "$rule"; then
      printf 'not-applicable\tnothing matched\n'
      return 0
    fi
  fi
}

run_before_commands() {
  if [ "$dry_run" = "yes" ]; then
    return 0
  fi
  local entry cmd a
  local args
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    cmd="$(jq -r '.command' <<<"$entry")"
    args=()
    while IFS= read -r a; do
      a="${a%$'\r'}"
      args+=("$a")
    done < <(jq -r '.args[]?' <<<"$entry")
    if command -v "$cmd" >/dev/null 2>&1; then
      "$cmd" ${args[@]+"${args[@]}"} >/dev/null 2>&1 || true
    fi
  done < <(jq -c '.before[]?' <<<"$1")
}

guarded_delete() {
  dc_is_canonical_path "$1" || return 1
  if dc_is_protected_target "$1" "$2" "$3"; then
    return 1
  fi
  safe_delete "$1"
}

dedupe_copy_unchanged() {
  local p="$1"
  dc_is_canonical_path "$p" || return 1
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  ! has_link_ancestor "$p" || return 1
  dc_is_under "$p" "$target" || return 1
  [ "$(dc_file_size "$p")" = "$2" ] || return 1
  [ "$(dc_sha256 "$p")" = "$3" ]
}

scan_made_for_current_home() {
  local scan_home
  scan_home="$(jq -r '.home // empty' "$scan_json")"
  scan_home="${scan_home%$'\r'}"
  [ -n "$scan_home" ] || return 1
  local folded_scan folded_home
  _dc_fold_into folded_scan "$scan_home"
  _dc_fold_into folded_home "$HOME"
  [ "$folded_scan" = "$folded_home" ]
}

run_dedupe_action() {
  if [ -z "$scan_json" ]; then
    printf 'not-applicable\tno scan.json\t0\n'
    return 0
  fi
  if [ -z "$target" ] || ! dc_is_canonical_path "$target"; then
    printf 'not-applicable\tno scan target\t0\n'
    return 0
  fi
  if ! scan_made_for_current_home; then
    printf 'refused\tscan made for another home\t0\n'
    return 0
  fi
  local group bytes sha p v
  local valid
  local groups=0 total=0 deleted=0 skipped=0
  while IFS= read -r group; do
    group="${group%$'\r'}"
    [ -n "$group" ] || continue
    bytes="$(jq -r '.bytes' <<<"$group")"
    bytes="${bytes%$'\r'}"
    sha="$(jq -r '.sha256' <<<"$group")"
    sha="${sha%$'\r'}"
    valid=()
    while IFS= read -r p; do
      p="${p%$'\r'}"
      [ -n "$p" ] || continue
      if dedupe_copy_unchanged "$p" "$bytes" "$sha"; then
        valid+=("$p")
      fi
    done < <(jq -r '.paths[]' <<<"$group")
    [ "${#valid[@]}" -ge 2 ] || continue
    groups=$((groups + 1))
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      if [ "$dry_run" = "yes" ]; then
        total=$((total + bytes))
      elif guarded_delete "$v" "$prot_paths" "$prot_names"; then
        deleted=$((deleted + 1))
        total=$((total + bytes))
      else
        skipped=$((skipped + 1))
      fi
    done < <(dc_dedupe_deletions "$prot_paths" "$prot_names" ${valid[@]+"${valid[@]}"})
  done < <(jq -c '.duplicates[]?' "$scan_json")
  emit_deletion_result "$groups" "" "$total" "$deleted" "$skipped"
}

protect_scan_folder() {
  local folder
  folder="$(dc_canonical_path "$1")" || return 0
  crit_paths="${crit_paths:+$crit_paths$'\n'}$folder"
  prot_paths="${prot_paths:+$prot_paths$'\n'}$folder"
}

stage_file_list() {
  local list_file="$1"
  shift
  ( dc_list_files "$@" ) >"$list_file" || { rm -f -- "$list_file"; return 1; }
}

delete_old_version_dir() {
  local d="$1"
  local f size list_file deleted=0 skipped=0 bytes=0
  list_file="$(mktemp "${TMPDIR:-/tmp}/dc-list.XXXXXX")"
  stage_file_list "$list_file" "$d" yes 0 0 "$crit_paths" "$crit_names" || return 1
  while IFS= read -r -d '' f; do
    size="$(dc_file_size "$f")"
    if guarded_delete "$f" "$crit_paths" "$crit_names"; then
      deleted=$((deleted + 1))
      bytes=$((bytes + size))
    else
      skipped=$((skipped + 1))
    fi
  done <"$list_file"
  rm -f -- "$list_file"
  prune_empty_dirs "$d" "$crit_paths" "$crit_names"
  rmdir -- "$d" 2>/dev/null || true
  printf '%s %s %s\n' "$deleted" "$skipped" "$bytes"
}

run_old_versions_action() {
  local p d d_deleted d_skipped d_bytes version_result
  local ok_paths=0 refused_paths="" bytes=0 deleted=0 skipped=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_refused_root "$p"; then
      refused_paths="$refused_paths$p"$'\n'
      continue
    fi
    ok_paths=$((ok_paths + 1))
    if [ "$ok_paths" -eq 1 ]; then
      run_before_commands "$1"
    fi
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if [ -L "$d" ] || dc_is_critical "$d" "$crit_paths" "$crit_names"; then
        continue
      fi
      if [ "$dry_run" = "yes" ]; then
        bytes=$((bytes + $(dc_folder_bytes "$d" "$crit_paths" "$crit_names")))
        continue
      fi
      version_result="$(delete_old_version_dir "$d")" || return 1
      read -r d_deleted d_skipped d_bytes <<<"$version_result"
      deleted=$((deleted + d_deleted))
      skipped=$((skipped + d_skipped))
      bytes=$((bytes + d_bytes))
    done < <(dc_old_version_dirs "$p")
  done < <(dc_rule_paths "$1" "$platform" "$target")
  emit_deletion_result "$ok_paths" "${refused_paths%$'\n'}" "$bytes" "$deleted" "$skipped"
}

run_tool_action() {
  local cmd a p bytes=0 code=0
  local args=()
  cmd="$(jq -r '.action.command' <<<"$1")"
  while IFS= read -r a; do
    a="${a%$'\r'}"
    args+=("$a")
  done < <(jq -r '.action.args[]?' <<<"$1")
  if [ "$dry_run" = "yes" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      bytes=$((bytes + $(dc_folder_bytes "$p" "$crit_paths" "$crit_names")))
    done < <(dc_rule_paths "$1" "$platform" "$target")
    printf 'dry-run\twould free %s bytes\t%s\n' "$bytes" "$bytes"
    return 0
  fi
  "$cmd" ${args[@]+"${args[@]}"} >/dev/null 2>&1 || code=$?
  if [ "$code" -eq 0 ]; then
    printf 'done\texit 0\t0\n'
  else
    printf 'failed\texit %s\t0\n' "$code"
  fi
}

safe_delete() {
  rm -f -- "$1"
}

prune_empty_dirs() {
  local d
  while IFS= read -r -d '' d; do
    if dc_is_critical "$d" "$2" "$3"; then
      continue
    fi
    rmdir -- "$d" 2>/dev/null || true
  done < <(find "$1" -xdev -mindepth 1 -depth -type d -print0 2>/dev/null)
}

prune_emptied_parents() {
  local d="${1%/*}"
  local root="$2"
  while [ "$d" != "$root" ] && dc_is_under "$d" "$root"; do
    if [ -L "$d" ] || dc_is_critical "$d" "$3" "$4"; then
      return 0
    fi
    rmdir -- "$d" 2>/dev/null || return 0
    d="${d%/*}"
  done
}

emit_deletion_result() {
  local ok_paths="$1"
  local refused_paths="$2"
  local bytes="$3"
  local deleted="$4"
  local skipped="$5"
  local first_refused p
  first_refused="${refused_paths%%$'\n'*}"
  if [ "$ok_paths" -eq 0 ] && [ -n "$refused_paths" ]; then
    printf 'refused\tprotected path %s\t0\n' "$first_refused"
  elif [ "$ok_paths" -eq 0 ]; then
    printf 'not-applicable\tnothing matched\t0\n'
  elif [ "$dry_run" = "yes" ]; then
    printf 'dry-run\twould free %s bytes\t%s\n' "$bytes" "$bytes"
  elif [ "$skipped" -gt 0 ]; then
    printf 'partial\tdeleted %s files, %s bytes, skipped %s\t%s\n' "$deleted" "$bytes" "$skipped" "$bytes"
  else
    printf 'done\tdeleted %s files, %s bytes, skipped %s\t%s\n' "$deleted" "$bytes" "$skipped" "$bytes"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf 'refused\tprotected path %s\n' "$p"
  done <<<"$refused_paths"
}

run_file_deletion() {
  local rule="$1"
  local recurse="$2"
  local min_bytes="$3"
  local age_days="$4"
  shift 4
  local p f size listed list_file emptied_dirs last_dir
  local ok_paths=0 refused_paths="" bytes=0 deleted=0 skipped=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_refused_root "$p"; then
      refused_paths="$refused_paths$p"$'\n'
      continue
    fi
    ok_paths=$((ok_paths + 1))
    if [ "$ok_paths" -eq 1 ]; then
      run_before_commands "$rule"
    fi
    if [ "$dry_run" = "yes" ]; then
      listed="$(dc_list_files "$p" "$recurse" "$min_bytes" "$age_days" "$crit_paths" "$crit_names" "$@" | dc_sum_file_bytes)" || return 1
      bytes=$((bytes + listed))
      continue
    fi
    emptied_dirs=""
    last_dir=""
    list_file="$(mktemp "${TMPDIR:-/tmp}/dc-list.XXXXXX")"
    stage_file_list "$list_file" "$p" "$recurse" "$min_bytes" "$age_days" "$crit_paths" "$crit_names" "$@" || return 1
    while IFS= read -r -d '' f; do
      if dc_is_protected_target "$f" "$crit_paths" "$crit_names"; then
        skipped=$((skipped + 1))
        continue
      fi
      size="$(dc_file_size "$f")"
      if safe_delete "$f"; then
        deleted=$((deleted + 1))
        bytes=$((bytes + size))
        if [ "${f%/*}" != "$last_dir" ]; then
          last_dir="${f%/*}"
          emptied_dirs="$emptied_dirs$f"$'\n'
        fi
      else
        skipped=$((skipped + 1))
      fi
    done <"$list_file"
    rm -f -- "$list_file"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      prune_emptied_parents "$f" "$p" "$crit_paths" "$crit_names"
    done <<<"$emptied_dirs"
  done < <(dc_rule_paths "$rule" "$platform" "$target")
  emit_deletion_result "$ok_paths" "${refused_paths%$'\n'}" "$bytes" "$deleted" "$skipped"
}

run_rule_action() {
  local rule="$1"
  local type recurse min_mb age_days inc
  local includes=()
  type="$(jq -r '.action.type' <<<"$rule")"
  case "$type" in
    tool)
      run_before_commands "$rule"
      run_tool_action "$rule"
      ;;
    clear-dir)
      run_file_deletion "$rule" yes 0 0
      ;;
    delete-files)
      recurse="$(jq -r 'if .action.recurse == true then "yes" else "no" end' <<<"$rule")"
      min_mb="$(jq -r '.action.minSizeMB // 0' <<<"$rule")"
      age_days="$(jq -r '.action.olderThanDays // 0' <<<"$rule")"
      while IFS= read -r inc; do
        inc="${inc%$'\r'}"
        includes+=("$inc")
      done < <(jq -r '.action.include[]?' <<<"$rule")
      run_file_deletion "$rule" "$recurse" "$((min_mb * BYTES_PER_MB))" "$age_days" ${includes[@]+"${includes[@]}"}
      ;;
    dedupe)
      run_before_commands "$rule"
      run_dedupe_action "$rule"
      ;;
    old-versions)
      run_old_versions_action "$rule"
      ;;
    *)
      printf 'failed\tunsupported action %s\t0\n' "$type"
      ;;
  esac
}

print_summary() {
  local free_start="$1"
  local free_end="$2"
  local dry_bytes="$3"
  local freed=$((free_end - free_start))
  if [ "$freed" -lt 0 ]; then
    freed=0
  fi
  if [ "$dry_run" = "yes" ]; then
    printf 'Dry run: nothing deleted. Would free about %s GB.\n' "$(dc_format_gb "$dry_bytes")"
  else
    printf 'Free space: %s GB -> %s GB (freed %s GB)\n' "$(dc_format_gb "$free_start")" "$(dc_format_gb "$free_end")" "$(dc_format_gb "$freed")"
  fi
  if [ -n "$skipped_ids" ]; then
    printf 'Skipped (needs admin): %s. Rerun the cleanup script as root yourself.\n' "${skipped_ids%, }"
  fi
  if [ -n "$refused_items" ]; then
    printf 'Refused: %s\n' "${refused_items%, }"
  fi
}

ordered_ids() {
  local requested="$1"
  local known id
  known="$(jq -r '.[].id' <<<"$all_rules")"
  known="${known//$'\r'/}"
  while IFS= read -r id; do
    if list_has "$requested" "$id"; then
      printf '%s\n' "$id"
    fi
  done <<<"$known"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! list_has "$known" "$id"; then
      printf '%s\n' "$id"
    fi
  done <<<"$requested"
}

main() {
  dc_canonicalize_env || fail_arg "HOME is not a canonical absolute path: ${HOME-}"
  local ids_arg="" log_arg="" scan_path
  scan_path="$(dc_default_scan_dir)/scan.json"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ids)
        [ "$#" -ge 2 ] || fail_arg "$1"
        ids_arg="${ids_arg:+$ids_arg,}$2"
        shift 2
        ;;
      --dry-run)
        dry_run="yes"
        shift
        ;;
      --log-path)
        [ "$#" -ge 2 ] || fail_arg "$1"
        log_arg="$2"
        shift 2
        ;;
      --scan-path)
        [ "$#" -ge 2 ] || fail_arg "$1"
        scan_path="$2"
        shift 2
        ;;
      --rules)
        [ "$#" -ge 2 ] || fail_arg "$1"
        rules_file="$2"
        shift 2
        ;;
      --help)
        printf '%s\n' "$USAGE"
        exit 0
        ;;
      *)
        fail_arg "$1"
        ;;
    esac
  done
  dc_require_jq || exit 5
  platform="$(dc_platform)" || exit 2
  export DC_PLATFORM="$platform"
  local requested
  requested="$(parse_ids "$ids_arg")"
  if [ -z "$requested" ]; then
    dry_run="yes"
    requested="$(jq -r --arg p "$platform" '.rules[] | select(.tier == "safe" and (.platforms | index($p))) | .id' "$rules_file" 2>/dev/null || true)"
    requested="${requested//$'\r'/}"
  fi
  if ! dc_scan_item_trusted "$(dirname -- "$scan_path")" "$scan_path"; then
    printf 'Scan folder refused: %s or %s is a link, not owned by you or writable by others\n' "$(dirname -- "$scan_path")" "$scan_path" >&2
    exit 3
  fi
  log_path="$(resolve_log_path "$log_arg" "$scan_path")" || exit 3
  dc_load_rules "$rules_file" "$platform" >/dev/null || exit 4
  all_rules="$(jq -c '.rules' "$rules_file")"
  if jq -e . "$scan_path" >/dev/null 2>&1; then
    scan_json="$scan_path"
    target="$(jq -r '.target // empty' "$scan_json")"
    target="${target//$'\r'/}"
  fi
  if [ -n "$target" ] && [ -d "$target" ]; then
    free_root="$target"
  else
    free_root="$HOME"
  fi
  crit_paths="$(dc_critical_paths "$all_rules" "$platform")"
  crit_names="$(dc_critical_names "$all_rules" "$platform")"
  crit_bad="$(dc_bad_critical_paths "$all_rules" "$platform")"
  local prot_rules
  prot_rules="$(jq -c '[.[] | select(.allowDuplicateRemoval != true)]' <<<"$all_rules")"
  prot_paths="$(dc_critical_paths "$prot_rules" "$platform")"
  prot_names="$(dc_critical_names "$prot_rules" "$platform")"
  protect_scan_folder "$(dirname -- "$scan_path")"

  local free_start free_end id rule before after decision out first detail result bytes action_type
  local failed=0 dry_total=0 line step_status
  free_start="$(free_bytes_or_zero "$free_root")"
  local dry_flag=false
  if [ "$dry_run" = "yes" ]; then
    dry_flag=true
  fi
  write_log_line "$log_path" - run start "$free_start" "$free_start" "dryRun=$dry_flag ids=$(printf '%s' "$requested" | paste -sd, -)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    rule="$(jq -c --arg id "$id" '.[] | select(.id == $id)' <<<"$all_rules")"
    before="$(free_bytes_or_zero "$free_root")"
    decision="$(step_decision "$id" "$rule")"
    out=""
    if [ -n "$decision" ]; then
      out="$decision"$'\n'
    else
      step_status=0
      out="$(run_rule_action "$rule")" || step_status=$?
      if [ "$step_status" -ne 0 ]; then
        out="failed${field_tab}step error (exit $step_status)${field_tab}0"
      fi
      out="$out"$'\n'
    fi
    first="${out%%$'\n'*}"
    IFS="$field_tab" read -r result detail bytes <<<"$first"
    bytes="${bytes:-0}"
    after="$(free_bytes_or_zero "$free_root")"
    action_type="-"
    if [ -n "$rule" ]; then
      action_type="$(jq -r '.action.type // "-"' <<<"$rule")"
    fi
    write_log_line "$log_path" "$id" "$action_type" "$result" "$before" "$after" "$detail"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      write_log_line "$log_path" "$id" "$action_type" refused "$before" "$after" "${line#refused"$field_tab"}"
    done <<<"${out#*$'\n'}"
    printf '%s %s: %s\n' "$result" "$id" "$detail"
    case "$result" in
      failed) failed=$((failed + 1)) ;;
      dry-run) dry_total=$((dry_total + bytes)) ;;
      skipped) skipped_ids="$skipped_ids$id, " ;;
      refused)
        case "$detail" in
          "protected path "*) refused_items="${refused_items}$id (protected path), " ;;
          *) refused_items="${refused_items}$id ($detail), " ;;
        esac
        ;;
    esac
  done < <(ordered_ids "$requested")
  free_end="$(free_bytes_or_zero "$free_root")"
  write_log_line "$log_path" - run end "$free_start" "$free_end" "failed=$failed"
  print_summary "$free_start" "$free_end" "$dry_total"
  if [ "$failed" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
