#!/usr/bin/env bats

load helpers

setup() {
  sandbox_setup
  . "$SCRIPTS/common.sh"
}

teardown() {
  sandbox_teardown
}

list_lines() {
  dc_list_files "$@" | tr '\0' '\n' | LC_ALL=C sort
}

@test "sandbox redirects HOME and TMPDIR into tests/.sandbox" {
  [[ "$HOME" == *"/.sandbox/"* ]]
  [[ "$TMPDIR" == *"/.sandbox/"* ]]
  [ "$DISK_CLEANUP_FORCE_NOT_ELEVATED" = "1" ]
}

@test "stubs log their name and arguments" {
  npm cache clean --force
  run stub_calls
  [ "$status" -eq 0 ]
  [ "$output" = "npm cache clean --force" ]
}

@test "sandbox_teardown refuses a path outside tests/.sandbox" {
  local keep_dir="$BATS_TEST_TMPDIR/keep"
  mkdir -p "$keep_dir"
  touch "$keep_dir/file.txt"
  SANDBOX="$keep_dir" sandbox_teardown
  [ -f "$keep_dir/file.txt" ]
}

@test "dc_require_jq succeeds when jq is on PATH" {
  run dc_require_jq
  [ "$status" -eq 0 ]
}

@test "dc_require_jq prints the install hint and returns 5 without jq" {
  local saved_path="$PATH"
  PATH="$SANDBOX/bin"
  run dc_require_jq
  PATH="$saved_path"
  [ "$status" -eq 5 ]
  [[ "$output" == *"disk-cleanup needs jq"* ]]
}

@test "dc_platform prints linux from DISK_CLEANUP_PLATFORM on an unknown uname" {
  run dc_platform
  [ "$status" -eq 0 ]
  [ "$output" = "linux" ] || [ "$output" = "macos" ]
}

@test "dc_platform returns 2 for an unknown override on an unknown uname" {
  case "$(uname -s)" in
    Darwin|Linux) skip "real Linux or macOS" ;;
  esac
  local saved_plat="$DISK_CLEANUP_PLATFORM"
  DISK_CLEANUP_PLATFORM=beos
  run dc_platform
  DISK_CLEANUP_PLATFORM="$saved_plat"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unsupported OS:"* ]]
}

@test "dc_load_rules prints only rules of the platform" {
  run dc_load_rules "$RULES" linux
  [ "$status" -eq 0 ]
  local ids
  ids="$(jq -r '.[].id' <<<"$output")"
  [[ "$ids" == *"npm-cache"* ]]
  [[ "$ids" != *"windows-update-cache"* ]]
}

@test "dc_load_rules returns 4 for a missing file" {
  run dc_load_rules "$SANDBOX/missing.json" linux
  [ "$status" -eq 4 ]
  [[ "$output" == *"Rules file invalid:"* ]]
}

@test "dc_load_rules returns 4 for a rule without tier" {
  local fix
  fix="$(fixture_rules '.rules[0] |= del(.tier)')"
  run dc_load_rules "$fix" linux
  [ "$status" -eq 4 ]
}

@test "dc_normalize_path strips trailing slashes but keeps root" {
  run dc_normalize_path "/a/b/"
  [ "$status" -eq 0 ]
  [ "$output" = "/a/b" ]
  run dc_normalize_path "/"
  [ "$status" -eq 0 ]
  [ "$output" = "/" ]
}

@test "dc_resolve_tokens expands HOME" {
  run dc_resolve_tokens '$''{HOME}/.npm'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.npm" ]
}

@test "R9 drops an entry whose token is unset" {
  unset DISK_CLEANUP_UNSET_VAR
  run dc_resolve_tokens '$''{DISK_CLEANUP_UNSET_VAR}/x'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run dc_expand_entry '$''{DISK_CLEANUP_UNSET_VAR}/x'
  [ -z "$output" ]
}

@test "dc_resolve_tokens returns 1 for an empty token" {
  export DISK_CLEANUP_EMPTY_VAR=
  run dc_resolve_tokens '$''{DISK_CLEANUP_EMPTY_VAR}/x'
  [ "$status" -eq 1 ]
}

@test "dc_resolve_tokens returns 1 when a token name is not valid" {
  run dc_resolve_tokens '$''{ProgramFiles(x86)}/x'
  [ "$status" -eq 1 ]
}

@test "dc_expand_entry prints an existing literal path" {
  mkdir -p "$HOME/.npm/_cacache"
  run dc_expand_entry '$''{HOME}/.npm/_cacache'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.npm/_cacache" ]
}

@test "dc_expand_entry prints nothing for a missing path and for a name pattern" {
  run dc_expand_entry '$''{HOME}/nope'
  [ -z "$output" ]
  run dc_expand_entry '**/*.mdf'
  [ -z "$output" ]
}

@test "dc_expand_entry expands a glob" {
  mkdir -p "$HOME/OneDrive A" "$HOME/OneDrive B"
  run dc_expand_entry '$''{HOME}/OneDrive*'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/OneDrive A"* ]]
  [[ "$output" == *"$HOME/OneDrive B"* ]]
}

@test "dc_match_entries prints the entries of the platform" {
  local rule
  rule="$(jq -c '.rules[] | select(.id == "npm-cache")' "$RULES")"
  run dc_match_entries "$rule" linux
  [ "$status" -eq 0 ]
  [ "$output" = '$''{HOME}/.npm/_cacache' ]
}

@test "dc_rule_paths keeps only paths under the target" {
  mkdir -p "$HOME/.npm/_cacache"
  local rule
  rule="$(jq -c '.rules[] | select(.id == "npm-cache")' "$RULES")"
  run dc_rule_paths "$rule" linux "$HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.npm/_cacache" ]
  run dc_rule_paths "$rule" linux "$SANDBOX/out"
  [ -z "$output" ]
}

@test "dc_critical_paths includes Documents even when it does not exist" {
  local rules_json
  rules_json="$(dc_load_rules "$RULES" linux)"
  run dc_critical_paths "$rules_json" linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/Documents"* ]]
}

@test "dc_critical_names lists name patterns without the prefix" {
  local rules_json
  rules_json="$(dc_load_rules "$RULES" linux)"
  run dc_critical_names "$rules_json" linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"*.mdf"* ]]
  [[ "$output" == *".git"* ]]
  [[ "$output" != *"**/"* ]]
}

@test "dc_is_under accepts equal and child paths only" {
  run dc_is_under "/a/b" "/a"
  [ "$status" -eq 0 ]
  run dc_is_under "/a" "/a"
  [ "$status" -eq 0 ]
  run dc_is_under "/ab" "/a"
  [ "$status" -eq 1 ]
  run dc_is_under "/x" "/"
  [ "$status" -eq 0 ]
}

@test "dc_is_canonical_path accepts only absolute paths without dot or empty segments" {
  run dc_is_canonical_path "/a/b"
  [ "$status" -eq 0 ]
  run dc_is_canonical_path "/a/b.c/.d"
  [ "$status" -eq 0 ]
  run dc_is_canonical_path "a/b"
  [ "$status" -eq 1 ]
  run dc_is_canonical_path "/a//b"
  [ "$status" -eq 1 ]
  run dc_is_canonical_path "/a/./b"
  [ "$status" -eq 1 ]
  run dc_is_canonical_path "/a/../b"
  [ "$status" -eq 1 ]
  run dc_is_canonical_path "/a/b/.."
  [ "$status" -eq 1 ]
}

@test "dc_name_matches is case insensitive" {
  local names=$'*.mdf\n*.ldf'
  run dc_name_matches "/data/DB.MDF" "$names"
  [ "$status" -eq 0 ]
  run dc_name_matches "/data/db.txt" "$names"
  [ "$status" -eq 1 ]
  run shopt -q nocasematch
  [ "$status" -eq 1 ]
}

@test "dc_is_critical matches a critical path and a name pattern" {
  local crit_paths="$HOME/Documents"
  local crit_names=$'.git\n*.mdf'
  run dc_is_critical "$HOME/Documents/a.txt" "$crit_paths" "$crit_names"
  [ "$status" -eq 0 ]
  run dc_is_critical "$HOME/x/.git/config" "$crit_paths" "$crit_names"
  [ "$status" -eq 0 ]
  run dc_is_critical "$HOME/.npm/x" "$crit_paths" "$crit_names"
  [ "$status" -eq 1 ]
}

@test "R7 refuses the volume root" {
  run dc_is_protected_target "/" "" ""
  [ "$status" -eq 0 ]
}

@test "R7 refuses HOME" {
  run dc_is_protected_target "$HOME" "" ""
  [ "$status" -eq 0 ]
}

@test "R7 refuses a path under a critical path" {
  local crit_paths="$HOME/Documents"
  local crit_names=".git"
  run dc_is_protected_target "$HOME/Documents/tmp" "$crit_paths" "$crit_names"
  [ "$status" -eq 0 ]
  run dc_is_protected_target "$HOME/.gradle/caches" "$crit_paths" "$crit_names"
  [ "$status" -eq 1 ]
}

@test "dc_is_temp_path detects TMPDIR and its children" {
  run dc_is_temp_path "$TMPDIR/out" "linux"
  [ "$status" -eq 0 ]
  run dc_is_temp_path "$SANDBOX/out" "linux"
  [ "$status" -eq 1 ]
}

@test "dc_is_temp_path resolves a missing tail under an existing ancestor" {
  run dc_is_temp_path "$TMPDIR/a/b/c" "linux"
  [ "$status" -eq 0 ]
}

@test "dc_is_elevated is false when forced" {
  DISK_CLEANUP_FORCE_NOT_ELEVATED=1 run dc_is_elevated
  [ "$status" -eq 1 ]
}

@test "dc_free_bytes prints a positive integer" {
  run dc_free_bytes "$HOME"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "dc_format_gb prints one decimal" {
  run dc_format_gb 1073741824
  [ "$status" -eq 0 ]
  [ "$output" = "1.0" ]
  run dc_format_gb 0
  [ "$status" -eq 0 ]
  [ "$output" = "0.0" ]
  run dc_format_gb 1610612736
  [ "$status" -eq 0 ]
  [ "$output" = "1.5" ]
}

@test "dc_file_size prints the apparent size" {
  make_file "$HOME/t/a.bin" 2097152
  run dc_file_size "$HOME/t/a.bin"
  [ "$status" -eq 0 ]
  [ "$output" = "2097152" ]
}

@test "dc_file_mtime_epoch orders old and new files" {
  make_file "$HOME/t/old" 1 202001010000
  make_file "$HOME/t/new" 1
  local old_e new_e
  old_e="$(dc_file_mtime_epoch "$HOME/t/old")"
  new_e="$(dc_file_mtime_epoch "$HOME/t/new")"
  [ "$old_e" -lt "$new_e" ]
}

@test "dc_file_mtime_iso prints UTC ISO 8601" {
  make_file "$HOME/t/old" 1 202001010000
  run dc_file_mtime_iso "$HOME/t/old"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ "$output" == 2019-12-31* ]] || [[ "$output" == 2020-01-01* ]]
}

@test "dc_sha256 prints lowercase hex" {
  mkdir -p "$HOME/t"
  printf 'abc' > "$HOME/t/abc"
  run dc_sha256 "$HOME/t/abc"
  [ "$status" -eq 0 ]
  [ "$output" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
}

@test "dc_list_files without recursion lists only the top level" {
  make_file "$HOME/t/a.txt" 10
  make_file "$HOME/t/sub/b.txt" 10
  run list_lines "$HOME/t" no 0 0 "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/t/a.txt" ]
}

@test "dc_list_files with recursion lists nested files" {
  make_file "$HOME/t/a.txt" 10
  make_file "$HOME/t/sub/b.txt" 10
  run list_lines "$HOME/t" yes 0 0 "" ""
  [ "$status" -eq 0 ]
  local expected
  expected="$(printf '%s\n%s' "$HOME/t/a.txt" "$HOME/t/sub/b.txt" | LC_ALL=C sort)"
  [ "$output" = "$expected" ]
}

@test "dc_list_files applies the minimum size exactly" {
  make_file "$HOME/t/big.bin" 2097152
  make_file "$HOME/t/small.bin" 1024
  run list_lines "$HOME/t" yes 1048576 0 "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/t/big.bin" ]
  run list_lines "$HOME/t" yes 2097153 0 "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dc_list_files applies the minimum age" {
  make_file "$HOME/t/old.log" 10 202001010000
  make_file "$HOME/t/new.log" 10
  run list_lines "$HOME/t" yes 0 30 "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/t/old.log" ]
}

@test "dc_list_files applies include patterns case-insensitively" {
  make_file "$HOME/t/A.LOG" 10
  make_file "$HOME/t/b.log" 10
  make_file "$HOME/t/c.txt" 10
  run list_lines "$HOME/t" yes 0 0 "" "" "*.log"
  [ "$status" -eq 0 ]
  local expected
  expected="$(printf '%s\n%s' "$HOME/t/A.LOG" "$HOME/t/b.log" | LC_ALL=C sort)"
  [ "$output" = "$expected" ]
}

@test "G6-R1 dc_list_files prunes critical folders and names" {
  local rules_json cp cn
  rules_json="$(dc_load_rules "$RULES" linux)"
  cp="$(dc_critical_paths "$rules_json" linux)"
  cn="$(dc_critical_names "$rules_json" linux)"
  make_file "$HOME/t/repo/.git/config" 10
  make_file "$HOME/t/db.mdf" 10
  make_file "$HOME/t/keep.txt" 10
  run list_lines "$HOME/t" yes 0 0 "$cp" "$cn"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/t/keep.txt" ]
}

@test "G6-R1 dc_list_files prunes a critical path under the root" {
  local rules_json cp cn
  rules_json="$(dc_load_rules "$RULES" linux)"
  cp="$(dc_critical_paths "$rules_json" linux)"
  cn="$(dc_critical_names "$rules_json" linux)"
  make_file "$HOME/Documents/x.txt" 10
  make_file "$HOME/t/y.txt" 10
  run list_lines "$HOME" yes 0 0 "$cp" "$cn"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/t/y.txt"* ]]
  [[ "$output" != *"/Documents/"* ]]
}

@test "R8 dc_list_files does not follow a symlinked folder" {
  make_file "$HOME/Documents/secret.txt" 10
  mkdir -p "$HOME/t"
  export MSYS=winsymlinks:nativestrict
  ln -s "$HOME/Documents" "$HOME/t/link" || skip "symlinks unavailable"
  run list_lines "$HOME/t" yes 0 0 "" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret.txt"* ]]
}

@test "G6-R2 dc_sum_file_bytes prints 0 for an empty list" {
  make_file "$HOME/t/dummy.bin" 2097152
  cd "$HOME/t"
  run bash -c ". \"$SCRIPTS/common.sh\"; printf '' | dc_sum_file_bytes"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "dc_sum_file_bytes sums disk usage of the listed files" {
  make_file "$HOME/t/1.bin" 2097152
  make_file "$HOME/t/2.bin" 2097152
  local total
  total="$(dc_list_files "$HOME/t" yes 0 0 "" "" | dc_sum_file_bytes)"
  [ "$total" -ge 4194304 ]
}

@test "dc_folder_bytes excludes critical subtrees" {
  local rules_json cp cn
  rules_json="$(dc_load_rules "$RULES" linux)"
  cp="$(dc_critical_paths "$rules_json" linux)"
  cn="$(dc_critical_names "$rules_json" linux)"
  make_file "$HOME/t/repo/.git/pack.bin" 2097152
  make_file "$HOME/t/a.bin" 1024
  run dc_folder_bytes "$HOME/t" "$cp" "$cn"
  [ "$status" -eq 0 ]
  [ "$output" -lt 2097152 ]
}

@test "dc_old_version_dirs keeps the highest version per extension" {
  mkdir -p "$HOME/t/ext/pub.ext-1.2.0"
  mkdir -p "$HOME/t/ext/pub.ext-1.10.0"
  mkdir -p "$HOME/t/ext/pub.other-0.1.0"
  run dc_old_version_dirs "$HOME/t/ext"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/t/ext/pub.ext-1.2.0" ]
}

@test "dc_old_version_dirs keeps names without a version and platform suffixes apart" {
  mkdir -p "$HOME/t/ext/readme"
  mkdir -p "$HOME/t/ext/pub.a-1.0.0-win32-x64"
  mkdir -p "$HOME/t/ext/pub.a-2.0.0"
  run dc_old_version_dirs "$HOME/t/ext"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "R11 dc_dedupe_deletions keeps the oldest and skips protected copies" {
  local rules_json cp cn
  rules_json="$(dc_load_rules "$RULES" linux)"
  cp="$(dc_critical_paths "$rules_json" linux)"
  cn="$(dc_critical_names "$rules_json" linux)"
  make_file "$HOME/Downloads/f.iso" 1024 202001010000
  make_file "$HOME/Desktop/f.iso" 1024
  make_file "$HOME/Videos2/f.iso" 1024
  run dc_dedupe_deletions "$cp" "$cn" "$HOME/Downloads/f.iso" "$HOME/Desktop/f.iso" "$HOME/Videos2/f.iso"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Videos2/f.iso" ]
}

@test "R11 dc_dedupe_deletions prints nothing when every other copy is protected" {
  local rules_json cp cn
  rules_json="$(dc_load_rules "$RULES" linux)"
  cp="$(dc_critical_paths "$rules_json" linux)"
  cn="$(dc_critical_names "$rules_json" linux)"
  make_file "$HOME/Documents/a/f.bin" 1024 202001010000
  make_file "$HOME/Documents/b/f.bin" 1024
  run dc_dedupe_deletions "$cp" "$cn" "$HOME/Documents/a/f.bin" "$HOME/Documents/b/f.bin"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1 dc_resolve_tokens keeps an ampersand in a token value" {
  HOME="$SANDBOX/home/a&b" run dc_resolve_tokens '$''{HOME}/.npm'
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/home/a&b/.npm" ]
}

@test "C1 dc_resolve_tokens resolves every occurrence of a token" {
  run dc_resolve_tokens '$''{HOME}/a:$''{HOME}/b'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/a:$HOME/b" ]
}

@test "C1 dc_resolve_tokens does not loop when the value contains the token" {
  export DC_SELF='x$''{DC_SELF}y'
  run dc_resolve_tokens '$''{DC_SELF}/z'
  [ "$status" -eq 1 ]
}

@test "C1 dc_critical_paths contains no double quote" {
  local rules_json
  rules_json="$(dc_load_rules "$RULES" linux)"
  run dc_critical_paths "$rules_json" linux
  [ "$status" -eq 0 ]
  [[ "$output" != *'"'* ]]
}

@test "R5 dc_canonical_path collapses repeated slashes and strips trailing slashes" {
  run dc_canonical_path "//a//b/"
  [ "$status" -eq 0 ]
  [ "$output" = "/a/b" ]
  run dc_canonical_path "/"
  [ "$status" -eq 0 ]
  [ "$output" = "/" ]
  run dc_canonical_path "/a/b///"
  [ "$status" -eq 0 ]
  [ "$output" = "/a/b" ]
}

@test "R5 dc_canonical_path returns 1 for dot segments and relative paths" {
  run dc_canonical_path "/a/./b"
  [ "$status" -eq 1 ]
  run dc_canonical_path "/a/../b"
  [ "$status" -eq 1 ]
  run dc_canonical_path "/a/b/.."
  [ "$status" -eq 1 ]
  run dc_canonical_path "a/b"
  [ "$status" -eq 1 ]
  run dc_canonical_path ""
  [ "$status" -eq 1 ]
}

@test "R5 dc_is_under is case sensitive on linux and case insensitive on macos" {
  DC_PLATFORM=linux run dc_is_under "$HOME/.AWS/credentials" "$HOME/.aws"
  [ "$status" -eq 1 ]
  DC_PLATFORM=macos run dc_is_under "$HOME/.AWS/credentials" "$HOME/.aws"
  [ "$status" -eq 0 ]
  DC_PLATFORM=macos run dc_is_under "$HOME/.AWSX/credentials" "$HOME/.aws"
  [ "$status" -eq 1 ]
}

@test "R5 dc_is_critical and dc_is_protected_target fold case on macos only" {
  local crit="$HOME/.aws"
  DC_PLATFORM=linux run dc_is_critical "$HOME/.AWS/credentials" "$crit" ""
  [ "$status" -eq 1 ]
  DC_PLATFORM=macos run dc_is_critical "$HOME/.AWS/credentials" "$crit" ""
  [ "$status" -eq 0 ]
  DC_PLATFORM=macos run dc_is_protected_target "$(printf '%s' "$HOME" | tr '[:lower:]' '[:upper:]')" "" ""
  [ "$status" -eq 0 ]
}

@test "R5 dc_is_protected_target protects a path that is not canonical" {
  run dc_is_protected_target "$HOME/a/../b" "" ""
  [ "$status" -eq 0 ]
  run dc_is_protected_target "$HOME//b" "" ""
  [ "$status" -eq 0 ]
  run dc_is_protected_target "relative/b" "" ""
  [ "$status" -eq 0 ]
}

@test "R5 dc_critical_paths drops a path that is not canonical and dc_bad_critical_paths names it" {
  local rules_json
  rules_json="$(jq -c '[{"id":"bad","tier":"critical","match":{"linux":["${HOME}/x/../y","${HOME}/good"]}}]' <<<'{}')"
  run dc_critical_paths "$rules_json" linux
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/good" ]
  run dc_bad_critical_paths "$rules_json" linux
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/x/../y" ]
}

@test "R5 dc_critical_paths collapses a doubled slash and reports no bad path" {
  local rules_json
  rules_json="$(jq -c '[{"id":"ok","tier":"critical","match":{"linux":["${HOME}//good/"]}}]' <<<'{}')"
  run dc_critical_paths "$rules_json" linux
  [ "$output" = "$HOME/good" ]
  run dc_bad_critical_paths "$rules_json" linux
  [ -z "$output" ]
}

@test "R5 dc_rule_paths keeps a path that is not canonical so the caller refuses it" {
  local rule
  rule="$(jq -c '{"id":"r","tier":"safe","match":{"linux":["${HOME}/a/../b"]}}' <<<'{}')"
  mkdir -p "$HOME/a" "$HOME/b"
  run dc_rule_paths "$rule" linux
  [ "$output" = "$HOME/a/../b" ]
  run dc_is_protected_target "$output" "" ""
  [ "$status" -eq 0 ]
}

@test "R5 dc_canonicalize_env canonicalizes HOME and unsets a bad TMPDIR" {
  HOME="$HOME/"
  TMPDIR="$SANDBOX/home/tmp//"
  run dc_canonicalize_env
  [ "$status" -eq 0 ]
  dc_canonicalize_env
  [ "$HOME" = "$SANDBOX/home" ]
  [ "$TMPDIR" = "$SANDBOX/home/tmp" ]
  TMPDIR="$HOME/tmp/.."
  dc_canonicalize_env 2>/dev/null
  [ -z "${TMPDIR+x}" ]
  HOME="$SANDBOX/./home"
  run dc_canonicalize_env
  [ "$status" -eq 1 ]
}

@test "R6 I1 dc_canonicalize_env rejects a HOME that is not an existing directory" {
  run env HOME="$SANDBOX/home " bash -c ". \"\$1\"; dc_canonicalize_env" _ "$SCRIPTS/common.sh"
  [ "$status" -eq 1 ]
  run env HOME="$SANDBOX/missing" bash -c ". \"\$1\"; dc_canonicalize_env" _ "$SCRIPTS/common.sh"
  [ "$status" -eq 1 ]
}

@test "R6 m2 dc_is_protected_target protects a path that contains HOME" {
  run dc_is_protected_target "$SANDBOX" "" ""
  [ "$status" -eq 0 ]
  run dc_is_protected_target "$SANDBOX/other" "" ""
  [ "$status" -eq 1 ]
}
