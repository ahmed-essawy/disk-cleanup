#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

readonly DEFAULT_MIN_FILE_MB=500
readonly MAX_MIN_FILE_MB=1048576
readonly MAX_FOLDERS=100
readonly BYTES_PER_MB=1048576
readonly tab=$'\t'
readonly rs=$'\x1e'

target=""
output_dir=""
min_file_mb="$DEFAULT_MIN_FILE_MB"
rules_file="$SCRIPT_DIR/../rules/rules.json"
platform=""
min_bytes=0
work_dir=""
rules_json=""
crit_paths=""
crit_names=""
crit_bad=""
prot_paths=""
prot_names=""
now_epoch=0
rule_count=0
rule_ids=()
rule_tiers=()
rule_types=()
rule_commands=()
rule_includes=()
rule_recurse=()
rule_min_mb=()
rule_age_days=()
rule_paths=()
rule_crit_paths=()
rule_names=()
rule_entry_counts=()

usage() {
  printf 'Usage: scan.sh [--target <path>] [--output-dir <path>] [--min-file-mb <n>] [--rules <path>] [--help]\n'
  printf "  --target       default \"\$HOME\"\n"
  printf "  --output-dir   default \"\${XDG_CACHE_HOME:-\$HOME/.cache}/diskscan\"\n"
  printf '  --min-file-mb  default 500, integer 1..1048576\n'
  printf '  --rules        default "<script dir>/../rules/rules.json"\n'
}

fail_arg() {
  printf 'Invalid argument: %s\n' "$1" >&2
  exit 2
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        [ "$#" -ge 2 ] || fail_arg "$1 needs a value"
        target="$2"
        shift 2
        ;;
      --output-dir)
        [ "$#" -ge 2 ] || fail_arg "$1 needs a value"
        output_dir="$2"
        shift 2
        ;;
      --min-file-mb)
        [ "$#" -ge 2 ] || fail_arg "$1 needs a value"
        min_file_mb="$2"
        shift 2
        ;;
      --rules)
        [ "$#" -ge 2 ] || fail_arg "$1 needs a value"
        rules_file="$2"
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        fail_arg "unknown option $1"
        ;;
    esac
  done
}

load_rule_arrays() {
  jq -r '.[] | [.id, .tier, (.action.type // ""), (.action.command // ""), ((.action.include // []) | join("\u001f")), ((.action.recurse // false) | tostring), ((.action.minSizeMB // 0) | tostring), ((.action.olderThanDays // 0) | tostring)] | join("\u001e")' <<<"$rules_json" > "$work_dir/rules_table.tsv"

  local idx=0
  local id tier type cmd inc rec mb age
  while IFS="$rs" read -r id tier type cmd inc rec mb age; do
    [ -n "$id" ] || continue
    rule_ids[idx]="$id"
    rule_tiers[idx]="$tier"
    rule_types[idx]="$type"
    rule_commands[idx]="$cmd"
    rule_includes[idx]="${inc//$'\x1f'/$'\n'}"
    rule_recurse[idx]="$rec"
    [ -n "$mb" ] || mb=0
    [ -n "$age" ] || age=0
    rule_min_mb[idx]="$mb"
    rule_age_days[idx]="$age"
    idx=$(( idx + 1 ))
  done < "$work_dir/rules_table.tsv"
  rule_count="$idx"

  local i r_json
  for (( i=0; i<rule_count; i++ )); do
    r_json="$(jq -c --argjson i "$i" '.[$i]' <<<"$rules_json")"
    rule_paths[i]="$(dc_rule_paths "$r_json" "$platform")"
    rule_entry_counts[i]="$(dc_match_entry_count "$r_json" "$platform")"
    if [ "${rule_tiers[i]}" = "critical" ]; then
      rule_crit_paths[i]="$(dc_critical_paths "[$r_json]" "$platform")"
      rule_names[i]="$(dc_critical_names "[$r_json]" "$platform")"
    else
      rule_crit_paths[i]=""
      rule_names[i]=""
    fi
  done
}

scan_rule_ids() {
  local p="$1"
  local is_file="$2"
  local b="$3"
  local ep="$4"
  local matched=()
  local i r_type r_tier r_rec r_mb r_age cut_epoch
  for (( i=0; i<rule_count; i++ )); do
    r_tier="${rule_tiers[i]}"
    r_type="${rule_types[i]}"
    if [ "$r_tier" = "critical" ]; then
      if dc_is_critical "$p" "${rule_crit_paths[i]}" "${rule_names[i]}"; then
        matched[${#matched[@]}]="${rule_ids[i]}"
        continue
      fi
    fi
    if [ "$r_type" = "clear-dir" ]; then
      local base_p
      while IFS= read -r base_p; do
        [ -n "$base_p" ] || continue
        if dc_is_under "$p" "$base_p"; then
          matched[${#matched[@]}]="${rule_ids[i]}"
          break
        fi
      done <<<"${rule_paths[i]}"
    elif [ "$r_type" = "delete-files" ] && [ "$is_file" -eq 1 ]; then
      r_rec="${rule_recurse[i]}"
      r_mb="${rule_min_mb[i]}"
      r_age="${rule_age_days[i]}"
      local min_file_limit=$(( r_mb * BYTES_PER_MB ))
      if [ "$b" -ge "$min_file_limit" ]; then
        local age_ok=1
        if [ "$r_age" -gt 0 ]; then
          cut_epoch=$(( now_epoch - r_age * 86400 ))
          if [ "$ep" -gt "$cut_epoch" ]; then
            age_ok=0
          fi
        fi
        if [ "$age_ok" -eq 1 ]; then
          local fname
          fname="${p##*/}"
          if dc_name_matches "$fname" "${rule_includes[i]}"; then
            local parent_dir
            parent_dir="${p%/*}"
            [ -n "$parent_dir" ] || parent_dir="/"
            local base_p
            while IFS= read -r base_p; do
              [ -n "$base_p" ] || continue
              if [ "$r_rec" = "false" ]; then
                if [ "$parent_dir" = "$base_p" ]; then
                  matched[${#matched[@]}]="${rule_ids[i]}"
                  break
                fi
              else
                if dc_is_under "$p" "$base_p"; then
                  matched[${#matched[@]}]="${rule_ids[i]}"
                  break
                fi
              fi
            done <<<"${rule_paths[i]}"
          fi
        fi
      fi
    fi
  done
  local res=""
  for id in "${matched[@]+"${matched[@]}"}"; do
    if [ -z "$res" ]; then
      res="$id"
    else
      res="$res,$id"
    fi
  done
  printf '%s' "$res"
}

scan_tier() {
  local ids="$1"
  if [ -z "$ids" ]; then
    printf 'critical'
    return 0
  fi
  local has_your_call=0
  local saved_ifs="$IFS"
  IFS=','
  local id cur_tier i
  for id in $ids; do
    [ -n "$id" ] || continue
    for (( i=0; i<rule_count; i++ )); do
      if [ "${rule_ids[i]}" = "$id" ]; then
        cur_tier="${rule_tiers[i]}"
        if [ "$cur_tier" = "critical" ]; then
          IFS="$saved_ifs"
          printf 'critical'
          return 0
        elif [ "$cur_tier" = "your_call" ]; then
          has_your_call=1
        fi
        break
      fi
    done
  done
  IFS="$saved_ifs"
  if [ "$has_your_call" -eq 1 ]; then
    printf 'your_call'
  else
    printf 'safe'
  fi
}

scan_folders() {
  du -kx -d 2 "$target" >"$work_dir/du.out" 2>>"$work_dir/du.err" || true
  local kb p bytes ids tier
  while IFS="$tab" read -r kb p; do
    [ -n "$p" ] || continue
    [ "$p" != "$target" ] || continue
    printf '%s\t%s\n' "$kb" "$p"
  done < "$work_dir/du.out" > "$work_dir/folders.unsorted"
  sort -t "$tab" -k1,1nr "$work_dir/folders.unsorted" > "$work_dir/folders.sorted" || true
  head -n "$MAX_FOLDERS" "$work_dir/folders.sorted" > "$work_dir/folders.top"

  while IFS="$tab" read -r kb p; do
    [ -n "$p" ] || continue
    bytes=$(( kb * 1024 ))
    ids="$(scan_rule_ids "$p" 0 "$bytes" 0)"
    tier="$(scan_tier "$ids")"
    jq -n -c \
      --arg path "$p" \
      --argjson bytes "$bytes" \
      --arg tier "$tier" \
      --arg ids "$ids" \
      '{path: $path, bytes: $bytes, tier: $tier, ruleIds: ($ids | split(",") | map(select(length > 0)))}' >> "$work_dir/folders.ndjson"
  done < "$work_dir/folders.top"
}

scan_large_files() {
  local k_size=$(( (min_bytes + 1023) / 1024 - 1 ))
  if [ "$k_size" -lt 0 ]; then
    k_size=0
  fi
  find "$target" -xdev -type f -size "+${k_size}k" -print0 2>>"$work_dir/find.err" >"$work_dir/large.list" || true

  local f f_size epoch modified ids tier
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    f_size="$(dc_file_size "$f" 2>/dev/null)" || continue
    if [ "$f_size" -lt "$min_bytes" ]; then
      continue
    fi
    epoch="$(dc_file_mtime_epoch "$f" 2>/dev/null)" || continue
    modified="$(dc_file_mtime_iso "$f" 2>/dev/null)" || continue
    ids="$(scan_rule_ids "$f" 1 "$f_size" "$epoch")"
    tier="$(scan_tier "$ids")"
    printf '%s\t%s\n' "$f_size" "$f" >> "$work_dir/large.tsv"
    jq -n -c \
      --arg path "$f" \
      --argjson bytes "$f_size" \
      --arg modified "$modified" \
      --arg tier "$tier" \
      --arg ids "$ids" \
      '{path: $path, bytes: $bytes, modified: $modified, tier: $tier, ruleIds: ($ids | split(",") | map(select(length > 0)))}' >> "$work_dir/large.ndjson"
  done < "$work_dir/large.list"
}

scan_duplicates() {
  if [ ! -s "$work_dir/large.tsv" ]; then
    return 0
  fi
  cut -f1 "$work_dir/large.tsv" | sort | uniq -d > "$work_dir/dups.sizes"
  if [ ! -s "$work_dir/dups.sizes" ]; then
    return 0
  fi
  local sz path hash
  while IFS="$tab" read -r sz path; do
    [ -n "$sz" ] || continue
    if grep -q "^${sz}$" "$work_dir/dups.sizes" 2>/dev/null; then
      hash="$(dc_sha256 "$path")"
      [ -n "$hash" ] || continue
      printf '%s\t%s\t%s\n' "$sz" "$hash" "$path" >> "$work_dir/dups.tsv"
    fi
  done < "$work_dir/large.tsv"

  if [ -s "$work_dir/dups.tsv" ]; then
    jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {bytes: (.[0] | tonumber), sha256: .[1], path: .[2]}) | group_by([.bytes, .sha256]) | map(select(length > 1) | {bytes: .[0].bytes, sha256: .[0].sha256, paths: (map(.path) | sort)}) | .[]' "$work_dir/dups.tsv" > "$work_dir/dups.ndjson"
  fi
}

rules_blocked() {
  [ -n "$crit_bad" ] && [ "$1" != "critical" ]
}

scan_rule_summary() {
  local i r_type r_tier available bytes paths p rule_bytes pb
  for (( i=0; i<rule_count; i++ )); do
    r_type="${rule_types[i]}"
    r_tier="${rule_tiers[i]}"
    paths=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if dc_is_under "$p" "$target"; then
        if [ -z "$paths" ]; then
          paths="$p"
        else
          paths="$paths"$'\n'"$p"
        fi
      fi
    done <<<"${rule_paths[i]}"
    if rules_blocked "$r_tier"; then
      paths=""
    fi

    if [ "$r_type" = "tool" ]; then
      available="false"
      if command -v "${rule_commands[i]}" >/dev/null 2>&1 && { [ "${rule_entry_counts[i]}" -eq 0 ] || [ -n "$paths" ]; }; then
        available="true"
      fi
    elif [ "$r_type" = "dedupe" ]; then
      if [ -s "$work_dir/dups.ndjson" ]; then
        available="true"
      else
        available="false"
      fi
    else
      if [ -n "$paths" ]; then
        available="true"
      else
        available="false"
      fi
    fi

    if [ "$r_tier" = "critical" ]; then
      rule_bytes=0
      if [ -n "$paths" ]; then
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          if [ -d "$p" ]; then
            pb="$({ du -skx "$p" 2>/dev/null || true; } | awk 'NR==1{printf "%.0f\n", $1*1024}')"
            rule_bytes=$(( rule_bytes + ${pb:-0} ))
          elif [ -f "$p" ]; then
            pb="$(dc_file_size "$p" 2>/dev/null || echo 0)"
            rule_bytes=$(( rule_bytes + pb ))
          fi
        done <<<"$paths"
      fi
      bytes="$rule_bytes"
    elif [ "$r_type" = "tool" ]; then
      if [ "${rule_entry_counts[i]}" -eq 0 ]; then
        bytes="null"
      else
        rule_bytes=0
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          pb="$(dc_folder_bytes "$p" "$crit_paths" "$crit_names")"
          rule_bytes=$(( rule_bytes + pb ))
        done <<<"$paths"
        bytes="$rule_bytes"
      fi
    elif [ "$r_type" = "compact-docker-vhdx" ]; then
      bytes="null"
    elif [ "$r_type" = "clear-dir" ]; then
      rule_bytes=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! dc_is_protected_target "$p" "$crit_paths" "$crit_names"; then
          pb="$(dc_folder_bytes "$p" "$crit_paths" "$crit_names")"
          rule_bytes=$(( rule_bytes + pb ))
        fi
      done <<<"$paths"
      bytes="$rule_bytes"
    elif [ "$r_type" = "delete-files" ]; then
      rule_bytes=0
      local rec="no"
      if [ "${rule_recurse[i]}" = "true" ]; then
        rec="yes"
      fi
      local min_b=$(( rule_min_mb[i] * BYTES_PER_MB ))
      local age="${rule_age_days[i]}"
      local inc_args=()
      while IFS= read -r inc_item; do
        [ -n "$inc_item" ] || continue
        inc_args[${#inc_args[@]}]="$inc_item"
      done <<<"${rule_includes[i]}"

      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! dc_is_protected_target "$p" "$crit_paths" "$crit_names"; then
          if [ ${#inc_args[@]} -gt 0 ]; then
            pb="$(dc_list_files "$p" "$rec" "$min_b" "$age" "$crit_paths" "$crit_names" ${inc_args[@]+"${inc_args[@]}"} | dc_sum_file_bytes)"
          else
            pb="$(dc_list_files "$p" "$rec" "$min_b" "$age" "$crit_paths" "$crit_names" | dc_sum_file_bytes)"
          fi
          rule_bytes=$(( rule_bytes + pb ))
        fi
      done <<<"$paths"
      bytes="$rule_bytes"
    elif [ "$r_type" = "old-versions" ]; then
      rule_bytes=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! dc_is_protected_target "$p" "$crit_paths" "$crit_names"; then
          local old_dir
          while IFS= read -r old_dir; do
            [ -n "$old_dir" ] || continue
            if ! dc_is_critical "$old_dir" "$crit_paths" "$crit_names"; then
              pb="$(dc_folder_bytes "$old_dir" "$crit_paths" "$crit_names")"
              rule_bytes=$(( rule_bytes + pb ))
            fi
          done < <(dc_old_version_dirs "$p")
        fi
      done <<<"$paths"
      bytes="$rule_bytes"
    elif [ "$r_type" = "dedupe" ]; then
      rule_bytes=0
      if [ -s "$work_dir/dups.ndjson" ]; then
        local dline d_bytes grp_paths gp del_count
        while IFS= read -r dline; do
          [ -n "$dline" ] || continue
          d_bytes="$(jq -r '.bytes' <<<"$dline")"
          d_bytes="${d_bytes%$'\r'}"
          grp_paths=()
          while IFS= read -r gp; do
            gp="${gp%$'\r'}"
            [ -n "$gp" ] || continue
            grp_paths[${#grp_paths[@]}]="$gp"
          done < <(jq -r '.paths[]' <<<"$dline")
          if [ ${#grp_paths[@]} -gt 0 ]; then
            del_count="$(dc_dedupe_deletions "$prot_paths" "$prot_names" ${grp_paths[@]+"${grp_paths[@]}"} | grep -c . || true)"
            rule_bytes=$(( rule_bytes + d_bytes * del_count ))
          fi
        done < "$work_dir/dups.ndjson"
      fi
      bytes="$rule_bytes"
    else
      bytes="null"
    fi
    if rules_blocked "$r_tier"; then
      available="false"
      bytes=0
    fi

    jq -n -c \
      --arg id "${rule_ids[i]}" \
      --arg tier "${rule_tiers[i]}" \
      --argjson available "$available" \
      --argjson bytes "$bytes" \
      --arg paths "$paths" \
      '{id: $id, tier: $tier, available: $available, bytes: $bytes, paths: ($paths | split("\n") | map(select(length > 0)))}' >> "$work_dir/rules.ndjson"
  done
}

scan_unreadable() {
  awk '
    /: Permission denied$/ {
      sub(/^[a-z]+: /, "");
      sub(/: Permission denied$/, "");
      sub(/^cannot read directory /, "");
      sub(/^cannot access /, "");
      sub(/^cannot open directory /, "");
      sub(/^'\''/, "");
      sub(/'\''$/, "");
      print;
    }
  ' "$work_dir/du.err" "$work_dir/find.err" 2>/dev/null | sort -u || true
}

main() {
  dc_require_jq || exit 5
  platform="$(dc_platform)" || exit 2
  export DC_PLATFORM="$platform"
  dc_canonicalize_env || fail_arg "HOME is not a canonical absolute path: ${HOME-}"
  target="$HOME"
  output_dir="$(dc_default_scan_dir)"
  parse_args "$@"
  [[ "$min_file_mb" =~ ^[0-9]+$ ]] || fail_arg "min-file-mb must be an integer from 1 to 1048576"
  [ "$min_file_mb" -ge 1 ] && [ "$min_file_mb" -le "$MAX_MIN_FILE_MB" ] || fail_arg "min-file-mb must be an integer from 1 to 1048576"
  min_bytes=$(( min_file_mb * BYTES_PER_MB ))
  [ -d "$target" ] || fail_arg "target not found: $target"
  target="$(dc_normalize_path "$(cd "$target" && pwd)")"

  case "$output_dir" in
    /*) ;;
    *) output_dir="$PWD/$output_dir" ;;
  esac
  output_dir="$(dc_normalize_path "$output_dir")"

  if dc_is_temp_path "$output_dir" "$platform"; then
    printf 'Output folder refused: %s is inside a Temp folder\n' "$output_dir" >&2
    exit 3
  fi

  if ! dc_scan_item_trusted "$output_dir" "$output_dir/scan.json"; then
    printf 'Output folder refused: %s or its scan.json is a link, not owned by you or writable by others\n' "$output_dir" >&2
    exit 3
  fi

  if ! dc_make_private_dir "$output_dir"; then
    printf 'Cannot create output folder: %s\n' "$output_dir" >&2
    exit 3
  fi

  rules_json="$(dc_load_rules "$rules_file" "$platform")" || exit 4

  work_dir="$output_dir/.work"
  rm -rf -- "$work_dir"
  mkdir -p "$work_dir"
  trap 'rm -rf -- "$work_dir"' EXIT

  : > "$work_dir/rules.ndjson"
  : > "$work_dir/folders.ndjson"
  : > "$work_dir/large.ndjson"
  : > "$work_dir/large.tsv"
  : > "$work_dir/dups.tsv"
  : > "$work_dir/dups.ndjson"
  : > "$work_dir/du.err"
  : > "$work_dir/find.err"

  crit_paths="$(dc_critical_paths "$rules_json" "$platform")"
  crit_names="$(dc_critical_names "$rules_json" "$platform")"
  crit_bad="$(dc_bad_critical_paths "$rules_json" "$platform")"
  local prot_json
  prot_json="$(jq -c '[.[] | select(.allowDuplicateRemoval != true)]' <<<"$rules_json")"
  prot_paths="$(dc_critical_paths "$prot_json" "$platform")"
  prot_names="$(dc_critical_names "$prot_json" "$platform")"
  now_epoch="$(date +%s)"

  load_rule_arrays
  scan_folders
  scan_large_files
  scan_duplicates
  scan_rule_summary
  local unreadable
  unreadable="$(scan_unreadable)"

  local drive_root drive_total drive_used drive_free df_info
  df_info="$(df -Pk "$target" | awk 'NR==2{printf "%s\t%.0f\t%.0f\t%.0f\n", $6, $2*1024, $3*1024, $4*1024}')"
  IFS="$tab" read -r drive_root drive_total drive_used drive_free <<<"$df_info"

  ( umask 077; jq -n \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg os "$platform" \
    --arg target "$target" \
    --arg home "$HOME" \
    --argjson minFileBytes "$min_bytes" \
    --arg root "$drive_root" \
    --argjson total "$drive_total" \
    --argjson used "$drive_used" \
    --argjson free "$drive_free" \
    --slurpfile rules "$work_dir/rules.ndjson" \
    --slurpfile folders "$work_dir/folders.ndjson" \
    --slurpfile largeFiles "$work_dir/large.ndjson" \
    --slurpfile duplicates "$work_dir/dups.ndjson" \
    --arg unreadable "$unreadable" \
    '{
      schemaVersion: 1,
      createdAt: $createdAt,
      os: $os,
      target: $target,
      home: $home,
      minFileBytes: $minFileBytes,
      drive: {root: $root, totalBytes: $total, usedBytes: $used, freeBytes: $free},
      rules: $rules,
      folders: $folders,
      largeFiles: ($largeFiles | sort_by(-.bytes)),
      duplicates: $duplicates,
      unreadable: ($unreadable | split("\n") | map(select(length > 0)))
    }' > "$output_dir/scan.json" )

  local counts n_folders n_large n_dups n_unread
  counts="$(jq -r '[(.folders | length), (.largeFiles | length), (.duplicates | length), (.unreadable | length)] | @tsv' "$output_dir/scan.json")"
  IFS="$tab" read -r n_folders n_large n_dups n_unread <<<"$counts"
  printf 'Scan complete: %s (%d folders, %d large files, %d duplicate groups, %d unreadable)\n' "$output_dir/scan.json" "$n_folders" "$n_large" "$n_dups" "$n_unread"
}

main "$@"
