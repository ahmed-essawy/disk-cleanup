dc_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'disk-cleanup needs jq. Install it: macOS '\''brew install jq'\'' (built in on macOS 15 and later), Debian/Ubuntu '\''\x73udo apt install jq'\'', Fedora '\''\x73udo dnf install jq'\''.\n' >&2
    return 5
  fi
}

dc_platform() {
  case "$(uname -s)" in
    Darwin)
      echo macos
      ;;
    Linux)
      echo linux
      ;;
    *)
      if [ "${DISK_CLEANUP_PLATFORM:-}" = "macos" ] || [ "${DISK_CLEANUP_PLATFORM:-}" = "linux" ]; then
        echo "$DISK_CLEANUP_PLATFORM"
      else
        printf 'Unsupported OS: %s\n' "$(uname -s)" >&2
        return 2
      fi
      ;;
  esac
}

dc_load_rules() {
  local rules_file="$1"
  local platform="$2"
  if [ ! -f "$rules_file" ] || ! jq -e '(.rules | type == "array") and all(.rules[]; (.id | type) == "string" and (.tier | type) == "string")' "$rules_file" >/dev/null 2>&1; then
    printf 'Rules file invalid: %s\n' "$rules_file" >&2
    return 4
  fi
  jq -c --arg p "$platform" '[.rules[] | select(.platforms | index($p))]' "$rules_file"
}

dc_normalize_path() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%"/"}" != "$p" ]; do
    p="${p%"/"}"
  done
  printf '%s\n' "$p"
}

dc_resolve_tokens() {
  local rest="$1" out="" token name value
  local re='\$\{([A-Za-z_][A-Za-z0-9_]*)\}'
  while [[ $rest =~ $re ]]; do
    name="${BASH_REMATCH[1]}"
    value="${!name-}"
    if [ -z "$value" ]; then
      return 1
    fi
    token="\${$name}"
    out="$out${rest%%"$token"*}$value"
    rest="${rest#*"$token"}"
  done
  out="$out$rest"
  if [[ "$out" =~ \$\{ ]]; then
    return 1
  fi
  printf '%s\n' "$out"
}

dc_canonical_path() {
  local p="$1"
  local slash="/" doubled="//"
  if [ "$p" = "/" ]; then
    printf '/\n'
    return 0
  fi
  while [[ "$p" == *"$doubled"* ]]; do
    p="${p//"$doubled"/$slash}"
  done
  while [ "${#p}" -gt 1 ] && [ "${p%"/"}" != "$p" ]; do
    p="${p%"/"}"
  done
  dc_is_canonical_path "$p" || return 1
  printf '%s\n' "$p"
}

dc_canonicalize_env() {
  local canonical
  canonical="$(dc_canonical_path "${HOME-}")" || return 1
  [ -d "$canonical" ] || return 1
  export HOME="$canonical"
  [ -n "${TMPDIR:-}" ] || return 0
  if canonical="$(dc_canonical_path "$TMPDIR")"; then
    export TMPDIR="$canonical"
  else
    printf 'TMPDIR ignored (not a canonical absolute path): %s\n' "$TMPDIR" >&2
    unset TMPDIR
  fi
}

_dc_emit_path() {
  dc_canonical_path "$1" || dc_normalize_path "$1"
}

dc_expand_entry() {
  case "$1" in
    '**/'*) return 0 ;;
  esac
  local p
  p="$(dc_resolve_tokens "$1")" || return 0
  case "$p" in
    *[\*\?]*)
      local item
      while IFS= read -r item; do
        if [ -n "$item" ]; then
          _dc_emit_path "$item"
        fi
      done < <(compgen -G "$p" || true)
      ;;
    *)
      if [ -e "$p" ]; then
        _dc_emit_path "$p"
      fi
      ;;
  esac
}

dc_match_entries() {
  jq -r --arg p "$2" '.match[$p] // [] | .[]' <<<"$1"
}

dc_match_entry_count() {
  dc_match_entries "$1" "$2" | awk 'END{print NR}'
}

dc_rule_paths() {
  local rule="$1"
  local platform="$2"
  local target="${3:-}"
  local entry path
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      if [ -n "$target" ]; then
        if dc_is_under "$path" "$target"; then
          printf '%s\n' "$path"
        fi
      else
        printf '%s\n' "$path"
      fi
    done < <(dc_expand_entry "$entry")
  done < <(dc_match_entries "$rule" "$platform") | awk '!seen[$0]++'
}

_dc_critical_candidate() {
  local canonical
  if canonical="$(dc_canonical_path "$1")"; then
    printf '%s\n' "$canonical"
  else
    printf '!%s\n' "$(dc_normalize_path "$1")"
  fi
}

_dc_critical_entries() {
  local rules_json="$1"
  local platform="$2"
  local entry path resolved
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      *[\*\?]*)
        while IFS= read -r path; do
          [ -n "$path" ] && _dc_critical_candidate "$path"
        done < <(dc_expand_entry "$entry")
        ;;
      *)
        if resolved="$(dc_resolve_tokens "$entry")"; then
          _dc_critical_candidate "$resolved"
        fi
        ;;
    esac
  done < <(jq -r --arg p "$platform" '.[] | select(.tier == "critical") | .match[$p] // [] | .[] | select(startswith("**/") | not)' <<<"$rules_json")
  return 0
}

dc_critical_paths() {
  _dc_critical_entries "$1" "$2" | awk '!/^!/ && !seen[$0]++'
}

dc_bad_critical_paths() {
  _dc_critical_entries "$1" "$2" | awk '/^!/ && !seen[$0]++ {print substr($0, 2)}'
}

dc_critical_names() {
  jq -r --arg p "$2" '.[] | select(.tier == "critical") | .match[$p] // [] | .[] | select(startswith("**/")) | .[3:]' <<<"$1" | awk '!seen[$0]++'
}

dc_is_canonical_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1/" in
    *//* | */./* | */../*) return 1 ;;
  esac
  return 0
}

_dc_fold_into() {
  if [ "${DC_PLATFORM:-}" = "macos" ]; then
    printf -v "$1" '%s' "$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  else
    printf -v "$1" '%s' "$2"
  fi
}

dc_is_under() {
  local path parent
  _dc_fold_into path "$1"
  _dc_fold_into parent "$2"
  _dc_is_under_folded "$path" "$parent"
}

_dc_is_under_folded() {
  local path="$1"
  local parent="$2"
  while [ "${#path}" -gt 1 ] && [ "${path%"/"}" != "$path" ]; do
    path="${path%"/"}"
  done
  while [ "${#parent}" -gt 1 ] && [ "${parent%"/"}" != "$parent" ]; do
    parent="${parent%"/"}"
  done
  if [ "$parent" = "/" ] && [ "${path#"/"}" != "$path" ]; then
    return 0
  fi
  if [ "$path" = "$parent" ]; then
    return 0
  fi
  case "$path" in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

dc_name_matches() {
  local path="$1"
  local names="$2"
  local restore_nocase=0
  if shopt -q nocasematch; then
    restore_nocase=1
  else
    shopt -s nocasematch
  fi
  local matched=0
  local nl=$'\n'
  local rest_p="$path"
  local seg rest_n name
  while [ -n "$rest_p" ]; do
    case "$rest_p" in
      */*)
        seg="${rest_p%%/*}"
        rest_p="${rest_p#*/}"
        ;;
      *)
        seg="$rest_p"
        rest_p=""
        ;;
    esac
    if [ -n "$seg" ]; then
      rest_n="$names"
      while [ -n "$rest_n" ]; do
        case "$rest_n" in
          *"$nl"*)
            name="${rest_n%%"$nl"*}"
            rest_n="${rest_n#*"$nl"}"
            ;;
          *)
            name="$rest_n"
            rest_n=""
            ;;
        esac
        if [ -n "$name" ]; then
          case "$seg" in
            $name)
              matched=1
              break 2
              ;;
          esac
        fi
      done
    fi
  done
  if [ "$restore_nocase" -eq 0 ]; then
    shopt -u nocasematch
  fi
  [ "$matched" -eq 1 ]
}

dc_is_critical() {
  local path="$1"
  local crit_paths="$2"
  local crit_names="$3"
  local nl=$'\n'
  local rest_p cp folded_path
  _dc_fold_into rest_p "$crit_paths"
  _dc_fold_into folded_path "$path"
  while [ -n "$rest_p" ]; do
    case "$rest_p" in
      *"$nl"*)
        cp="${rest_p%%"$nl"*}"
        rest_p="${rest_p#*"$nl"}"
        ;;
      *)
        cp="$rest_p"
        rest_p=""
        ;;
    esac
    if [ -n "$cp" ] && _dc_is_under_folded "$folded_path" "$cp"; then
      return 0
    fi
  done
  dc_name_matches "$path" "$crit_names"
}

dc_is_protected_target() {
  local path="$1"
  local crit_paths="$2"
  local crit_names="$3"
  local norm folded_norm folded_other mount_point
  norm="$(dc_normalize_path "$path")"
  if [ "$norm" = "/" ]; then
    return 0
  fi
  dc_is_canonical_path "$norm" || return 0
  _dc_fold_into folded_norm "$norm"
  _dc_fold_into folded_other "$(dc_normalize_path "$HOME")"
  if _dc_is_under_folded "$folded_other" "$folded_norm"; then
    return 0
  fi
  mount_point="$(df -P "$path" 2>/dev/null | awk 'NR==2{print $6}')"
  if [ -n "$mount_point" ]; then
    _dc_fold_into folded_other "$(dc_normalize_path "$mount_point")"
    if [ "$folded_norm" = "$folded_other" ]; then
      return 0
    fi
  fi
  dc_is_critical "$norm" "$crit_paths" "$crit_names"
}

dc_resolve_dir() {
  local a="$1"
  local tail=""
  while [ -n "$a" ] && [ ! -d "$a" ]; do
    tail="/$(basename "$a")$tail"
    a="$(dirname "$a")"
    if [ "$a" = "/" ] || [ "$a" = "." ]; then
      break
    fi
  done
  if [ -d "$a" ]; then
    printf '%s%s\n' "$(cd -P "$a" 2>/dev/null && pwd -P)" "$tail"
  else
    printf '%s\n' "$1"
  fi
}

dc_is_temp_path() {
  local path="$1"
  local platform="$2"
  local roots=()
  if [ -n "${TMPDIR:-}" ]; then
    roots=("${roots[@]+"${roots[@]}"}" "$TMPDIR")
  fi
  roots=("${roots[@]+"${roots[@]}"}" "/tmp" "/var/tmp" "/private/tmp" "/private/var/folders")
  local r_path
  r_path="$(dc_resolve_dir "$path")"
  if [ "$platform" = "macos" ]; then
    r_path="$(tr '[:upper:]' '[:lower:]' <<<"$r_path")"
  fi
  local root r_root
  for root in "${roots[@]+"${roots[@]}"}"; do
    [ -d "$root" ] || continue
    r_root="$(dc_resolve_dir "$root")"
    if [ "$platform" = "macos" ]; then
      r_root="$(tr '[:upper:]' '[:lower:]' <<<"$r_root")"
    fi
    if dc_is_under "$r_path" "$r_root"; then
      return 0
    fi
  done
  return 1
}

dc_is_elevated() {
  if [ "${DISK_CLEANUP_FORCE_NOT_ELEVATED:-}" = "1" ]; then
    return 1
  fi
  [ "$(id -u)" -eq 0 ]
}

dc_free_bytes() {
  df -Pk "$1" | awk 'NR==2{printf "%.0f\n", $4*1024}'
}

dc_format_gb() {
  awk -v b="$1" 'BEGIN{printf "%.1f\n", b/1073741824}'
}

_dc_stat_is_gnu() {
  stat -c %s / >/dev/null 2>&1
}

dc_file_size() {
  if _dc_stat_is_gnu; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

dc_file_mtime_epoch() {
  if _dc_stat_is_gnu; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

dc_file_mtime_iso() {
  local epoch
  epoch="$(dc_file_mtime_epoch "$1")"
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

dc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

dc_list_files() {
  [ "$#" -ge 6 ] || return 0
  local root="$1"
  local recurse="$2"
  local min_bytes="$3"
  local min_age_days="$4"
  local crit_paths="$5"
  local crit_names="$6"
  shift 6
  local args=("$root")
  if [ "$recurse" = "no" ]; then
    args=(${args[@]+"${args[@]}"} -maxdepth 1)
  fi
  args=(${args[@]+"${args[@]}"} -xdev)
  local prune_exprs=()
  local p
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    if [ "$p" != "$root" ] && dc_is_under "$p" "$root"; then
      if [ "${#prune_exprs[@]}" -gt 0 ]; then
        prune_exprs=(${prune_exprs[@]+"${prune_exprs[@]}"} -o)
      fi
      prune_exprs=(${prune_exprs[@]+"${prune_exprs[@]}"} -path "$p")
    fi
  done <<<"$crit_paths"
  local n
  while IFS= read -r n || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    if [ "${#prune_exprs[@]}" -gt 0 ]; then
      prune_exprs=(${prune_exprs[@]+"${prune_exprs[@]}"} -o)
    fi
    prune_exprs=(${prune_exprs[@]+"${prune_exprs[@]}"} -iname "$n")
  done <<<"$crit_names"
  if [ "${#prune_exprs[@]}" -gt 0 ]; then
    args=(${args[@]+"${args[@]}"} '(' ${prune_exprs[@]+"${prune_exprs[@]}"} ')' -prune -o)
  fi
  args=(${args[@]+"${args[@]}"} -type f)
  if [ "$#" -gt 0 ]; then
    local inc_exprs=()
    local inc
    for inc in "$@"; do
      if [ "${#inc_exprs[@]}" -gt 0 ]; then
        inc_exprs=(${inc_exprs[@]+"${inc_exprs[@]}"} -o)
      fi
      inc_exprs=(${inc_exprs[@]+"${inc_exprs[@]}"} -iname "$inc")
    done
    args=(${args[@]+"${args[@]}"} '(' ${inc_exprs[@]+"${inc_exprs[@]}"} ')')
  fi
  if [ "$min_bytes" -gt 0 ]; then
    local min_k=$(( (min_bytes + 1023) / 1024 - 1 ))
    args=(${args[@]+"${args[@]}"} -size "+${min_k}k")
  fi
  if [ "$min_age_days" -gt 0 ]; then
    local mtime_arg=$(( min_age_days - 1 ))
    args=(${args[@]+"${args[@]}"} -mtime "+$mtime_arg")
  fi
  args=(${args[@]+"${args[@]}"} -print0)
  local f sz
  { find ${args[@]+"${args[@]}"} 2>/dev/null || true; } | while IFS= read -r -d '' f; do
    if [ "$min_bytes" -gt 0 ]; then
      sz="$(dc_file_size "$f" 2>/dev/null)" || continue
      [ "$sz" -ge "$min_bytes" ] || continue
    fi
    if dc_is_critical "$f" "$crit_paths" "$crit_names"; then
      continue
    fi
    printf '%s\0' "$f"
  done || true
  return 0
}

dc_sum_file_bytes() {
  { xargs -0 du -k /dev/null 2>/dev/null || true; } | awk '{s+=$1} END{printf "%.0f\n", s*1024}'
}

dc_folder_bytes() {
  dc_list_files "$1" yes 0 0 "$2" "$3" | dc_sum_file_bytes
}

dc_extension_refs() {
  [ -f "$1/extensions.json" ] || return 0
  { jq -r '.[]? | (.relativeLocation? // empty), ((.location.path? // .location.fsPath? // empty) | split("/") | last // empty)' "$1/extensions.json" 2>/dev/null || true; } | tr -d '\r'
}

dc_old_version_dirs() {
  local dir="$1"
  local field_sep=$'\t'
  local re='^(.+)-([0-9]+(\.[0-9]+){1,3})(-.+)?$'
  local d name key v1 v2 v3 v4 refs
  refs="$(dc_extension_refs "$dir")"
  while IFS= read -r -d '' d; do
    name="${d##*/}"
    [[ $name =~ $re ]] || continue
    key="${BASH_REMATCH[1]}${BASH_REMATCH[4]}"
    IFS=. read -r v1 v2 v3 v4 <<<"${BASH_REMATCH[2]}"
    v1="${v1:-0}"
    v2="${v2:-0}"
    v3="${v3:-0}"
    v4="${v4:-0}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$v1" "$v2" "$v3" "$v4" "$d"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null) |
    LC_ALL=C sort -t "$field_sep" -k1,1 -k2,2nr -k3,3nr -k4,4nr -k5,5nr |
    awk -F '\t' '$1==prev{print $6} {prev=$1}' |
    while IFS= read -r d; do
      case $'\n'"$refs"$'\n' in
        *$'\n'"${d##*/}"$'\n'*) ;;
        *) printf '%s\n' "$d" ;;
      esac
    done
}

dc_file_identity() {
  if _dc_stat_is_gnu; then
    stat -c '%d:%i' "$1"
  else
    stat -f '%d:%i' "$1"
  fi
}

dc_dedupe_deletions() {
  [ "$#" -ge 2 ] || return 0
  local prot_paths="$1"
  local prot_names="$2"
  shift 2
  local field_sep=$'\t'
  local p epoch id victim
  while IFS= read -r victim; do
    [ -n "$victim" ] || continue
    if ! dc_is_critical "$victim" "$prot_paths" "$prot_names"; then
      printf '%s\n' "$victim"
    fi
  done < <(
    for p in "$@"; do
      [ -f "$p" ] || continue
      epoch="$(dc_file_mtime_epoch "$p")" || continue
      id="$(dc_file_identity "$p")" || continue
      printf '%s\t%s\t%s\n' "$epoch" "$id" "$p"
    done | LC_ALL=C sort -t "$field_sep" -k1,1n -k3,3 |
      awk -F '\t' '{ n[$2]++; ids[NR] = $2; rows[NR] = substr($0, length($1) + length($2) + 3) } END { for (r = 2; r <= NR; r++) if (n[ids[r]] == 1) print rows[r] }'
  )
}

dc_default_scan_dir() {
  local cache_home="${XDG_CACHE_HOME:-}"
  case "$cache_home" in
    /*) ;;
    *) cache_home="$HOME/.cache" ;;
  esac
  printf '%s/diskscan\n' "$cache_home"
}

dc_scan_item_trusted() {
  local item
  for item in "$@"; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    [ ! -L "$item" ] || return 1
    [ -O "$item" ] || return 1
    [ -z "$(find "$item" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ] || return 1
  done
  return 0
}

dc_make_private_dir() {
  mkdir -p -- "$(dirname -- "$1")" 2>/dev/null || return 1
  [ -d "$1" ] && return 0
  ( umask 077 && mkdir -- "$1" ) 2>/dev/null
}
