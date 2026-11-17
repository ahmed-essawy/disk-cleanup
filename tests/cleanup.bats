#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  sandbox_setup
}

teardown() {
  sandbox_teardown
}

run_cleanup() {
  run bash "$SCRIPTS/cleanup.sh" --scan-path "$SANDBOX/out/scan.json" --log-path "$SANDBOX/out/cleanup.log" "$@"
}

run_cleanup_env() {
  local assignment="$1"
  shift
  run env "$assignment" bash "$SCRIPTS/cleanup.sh" --scan-path "$SANDBOX/out/scan.json" --log-path "$SANDBOX/out/cleanup.log" "$@"
}

log_file() {
  printf '%s' "$SANDBOX/out/cleanup.log"
}

@test "R1 refuses every critical id" {
  local ids count
  ids="$(jq -r '[.rules[] | select(.tier == "critical") | .id] | join(",")' "$RULES")"
  ids="${ids//$'\r'/}"
  count="$(jq -r '[.rules[] | select(.tier == "critical")] | length' "$RULES")"
  count="${count//$'\r'/}"
  make_file "$HOME/Documents/keep.txt" 10
  local before
  before="$(tree_snapshot)"
  run_cleanup --ids "$ids"
  [ "$status" -eq 0 ]
  [ "$(tree_snapshot)" = "$before" ]
  [ -z "$(stub_calls)" ]
  [ "$(awk -F '\t' '$4 == "refused" && $7 == "critical"' "$(log_file)" | wc -l)" -eq "$count" ]
}

@test "R1 refuses a critical rule even when the rules file gives it an action" {
  local fixture
  fixture="$(fixture_rules '(.rules[] | select(.id == "user-folders") | .action) = {"type": "clear-dir"}')"
  make_file "$HOME/Documents/keep.txt" 10
  run_cleanup --ids user-folders --rules "$fixture"
  [ -e "$HOME/Documents/keep.txt" ]
  [[ "$output" == *"refused user-folders: critical"* ]]
}

@test "R2 refuses an unknown id" {
  run_cleanup --ids no-such-rule
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused no-such-rule: unknown id"* ]]
  [[ "$output" == *"Refused: no-such-rule (unknown id)"* ]]
}

@test "R3 refuses a rule without an action" {
  local fixture
  fixture="$(fixture_rules '(.rules[] | select(.id == "maven-repository") | .action) = null')"
  make_file "$HOME/.m2/repository/a.jar" 10
  run_cleanup --ids maven-repository --rules "$fixture"
  [ -e "$HOME/.m2/repository/a.jar" ]
  [[ "$output" == *"refused maven-repository: no action"* ]]
}

@test "R4 runs a dry run over safe ids when no ids are given" {
  make_file "$TMPDIR/old.tmp" 10 202001010000
  make_file "$HOME/.gradle/caches/a.bin" 10
  local before
  before="$(tree_snapshot)"
  run_cleanup
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(head -n 1 "$(log_file)")"
  [ "$(printf '%s' "$first_line" | cut -f2)" = "-" ]
  [ "$(printf '%s' "$first_line" | cut -f4)" = "start" ]
  [[ "$(printf '%s' "$first_line" | cut -f7)" == "dryRun=true ids=user-temp"* ]]
  [ -z "$(awk -F '\t' '$2 != "-" && $4 != "dry-run" && $4 != "skipped" && $4 != "not-applicable"' "$(log_file)")" ]
  [ "$(tree_snapshot)" = "$before" ]
  [ -z "$(stub_calls)" ]
  [[ "$output" == *"Dry run: nothing deleted."* ]]
}

@test "R5 dry run with ids deletes nothing and runs no tool" {
  make_file "$TMPDIR/old.tmp" 10 202001010000
  make_file "$HOME/.npm/_cacache/x.bin" 10
  make_file "$HOME/.gradle/caches/y.bin" 10
  local before
  before="$(tree_snapshot)"
  run_cleanup --dry-run --ids user-temp,npm-cache,gradle-cache
  [ "$(tree_snapshot)" = "$before" ]
  [ -z "$(stub_calls)" ]
  [[ "$output" == *"dry-run gradle-cache: would free"* ]]
  [[ "$output" == *"Dry run: nothing deleted. Would free about"* ]]
  printf '%s\n' "$output" | grep -Eq '^Dry run: nothing deleted\. Would free about [0-9]+\.[0-9] GB\.$'
}

@test "clears the gradle cache and keeps its siblings" {
  make_file "$HOME/.gradle/caches/modules-2/a.bin" 10
  make_file "$HOME/.gradle/caches/b.bin" 10
  make_file "$HOME/.gradle/gradle.properties" 10
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -d "$HOME/.gradle/caches" ]
  [ -z "$(ls -A "$HOME/.gradle/caches")" ]
  [ -e "$HOME/.gradle/gradle.properties" ]
  [[ "$(stub_calls)" == *"gradle --stop"* ]]
  [[ "$output" == *"done gradle-cache: deleted 2 files"* ]]
  printf '%s\n' "$output" | grep -Eq '^Free space: [0-9]+\.[0-9] GB -> [0-9]+\.[0-9] GB \(freed [0-9]+\.[0-9] GB\)$'
}

@test "runs the npm tool command" {
  make_file "$HOME/.npm/_cacache/x.bin" 10
  run_cleanup --ids npm-cache
  [ "$status" -eq 0 ]
  [[ "$(stub_calls)" == *"npm cache clean --force"* ]]
  [[ "$output" == *"done npm-cache: exit 0"* ]]
}

@test "R7 refuses a temp folder inside a critical folder" {
  make_file "$HOME/Documents/tmp/old.tmp" 10 202001010000
  TMPDIR="$HOME/Documents/tmp" run_cleanup --ids user-temp
  [ -e "$HOME/Documents/tmp/old.tmp" ]
  [ -n "$(awk -F '\t' '$4 == "refused" && index($7, "protected path ") == 1' "$(log_file)")" ]
}

@test "R8 keeps critical subtrees and name patterns inside a target" {
  make_file "$HOME/.gradle/caches/x/repo/.git/config" 10
  make_file "$HOME/.gradle/caches/db.mdf" 10
  make_file "$HOME/.gradle/caches/junk.bin" 10
  run_cleanup --ids gradle-cache
  [ -e "$HOME/.gradle/caches/x/repo/.git/config" ]
  [ -e "$HOME/.gradle/caches/db.mdf" ]
  [ ! -e "$HOME/.gradle/caches/junk.bin" ]
}

@test "R8 does not follow a symlink inside a target" {
  make_file "$HOME/Documents/precious.txt" 10
  make_file "$HOME/.gradle/caches/junk.bin" 10
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Documents" "$HOME/.gradle/caches/link" || skip "symlinks not available"
  run_cleanup --ids gradle-cache
  [ -e "$HOME/Documents/precious.txt" ]
  [ ! -e "$HOME/.gradle/caches/junk.bin" ]
}

@test "R6 skips an admin step when not elevated" {
  local fixture
  fixture="$(fixture_rules $'.rules += [{"id":"fixture-admin","tier":"safe","platforms":["linux","macos"],"match":{"linux":["${HOME}/admin-cache"],"macos":["${HOME}/admin-cache"]},"action":{"type":"clear-dir"},"needsAdmin":true,"description":"x","reason":"x"}]')"
  make_file "$HOME/admin-cache/a.bin" 10
  run_cleanup --ids fixture-admin --rules "$fixture"
  [ -e "$HOME/admin-cache/a.bin" ]
  [[ "$output" == *"skipped fixture-admin: needs admin: rerun the cleanup script as root yourself"* ]]
  [[ "$output" == *"Skipped (needs admin): fixture-admin. Rerun the cleanup script as root yourself."* ]]
  [[ "$(stub_calls)" != *sudo* ]]
  [[ "$(stub_calls)" != *runas* ]]
}

@test "R9 drops a match entry with an unset variable" {
  unset DISK_CLEANUP_UNSET_VAR
  local fixture before
  fixture="$(fixture_rules $'.rules += [{"id":"fixture-unset","tier":"safe","platforms":["linux","macos"],"match":{"linux":["${DISK_CLEANUP_UNSET_VAR}/x"],"macos":["${DISK_CLEANUP_UNSET_VAR}/x"]},"action":{"type":"clear-dir"},"needsAdmin":false,"description":"x","reason":"x"}]')"
  before="$(tree_snapshot)"
  run_cleanup --ids fixture-unset --rules "$fixture"
  [ "$status" -eq 0 ]
  [ "$(tree_snapshot)" = "$before" ]
  [[ "$output" == *"not-applicable fixture-unset: nothing matched"* ]]
}

@test "writes seven tab-separated columns with free space" {
  make_file "$HOME/.npm/_cacache/x.bin" 10
  run_cleanup --ids npm-cache,no-such-rule
  [ -z "$(awk -F '\t' 'NF != 7' "$(log_file)")" ]
  [ -z "$(awk -F '\t' '$5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/' "$(log_file)")" ]
  [ "$(head -n 1 "$(log_file)" | cut -f4)" = "start" ]
  [ "$(tail -n 1 "$(log_file)" | cut -f4)" = "end" ]
  [ "$(tail -n 1 "$(log_file)" | cut -f7)" = "failed=0" ]
}

@test "R10 falls back to the default log path when the log path is inside Temp" {
  run --separate-stderr bash "$SCRIPTS/cleanup.sh" --scan-path "$SANDBOX/out/scan.json" --log-path "$TMPDIR/cleanup.log" --ids npm-cache
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Log path refused (inside Temp), using $SANDBOX/out/cleanup.log"* ]]
  [ ! -e "$TMPDIR/cleanup.log" ]
  [ -e "$SANDBOX/out/cleanup.log" ]
}

@test "exits 1 when a tool fails" {
  add_failing_stub npm
  make_file "$HOME/.npm/_cacache/x.bin" 10
  run_cleanup --ids npm-cache
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed npm-cache: exit 1"* ]]
}

@test "exits 2 on an unknown argument" {
  run_cleanup --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid argument: --bogus"* ]]
}

@test "R8 refuses a matched root that is a symlink" {
  make_file "$HOME/Documents/precious.txt" 10
  mkdir -p "$HOME/.gradle"
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Documents" "$HOME/.gradle/caches" || skip "symlinks not available"
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -e "$HOME/Documents/precious.txt" ]
  [[ "$output" == *"refused gradle-cache: protected path "* ]]
}

@test "R7 re-checks the guard on every file in the delete loop" {
  make_file "$HOME/Documents/keep.txt" 10
  make_file "$HOME/.gradle/caches/junk.bin" 10
  run bash -c '
    . "$SCRIPTS/cleanup.sh"
    platform=linux
    dry_run=no
    all_rules="$(jq -c .rules "$RULES")"
    crit_paths="$(dc_critical_paths "$all_rules" "$platform")"
    crit_names="$(dc_critical_names "$all_rules" "$platform")"
    dc_list_files() { printf "%s\0" "$HOME/Documents/keep.txt" "$HOME/.gradle/caches/junk.bin"; }
    rule="$(jq -c ".rules[] | select(.id == \"gradle-cache\")" "$RULES")"
    run_file_deletion "$rule" yes 0 0
  '
  [ -e "$HOME/Documents/keep.txt" ]
  [ ! -e "$HOME/.gradle/caches/junk.bin" ]
  [[ "$output" == *"partial"*"skipped 1"* ]]
}

@test "R10 exits 3 for an unusable log path before it loads the rules" {
  run --separate-stderr bash "$SCRIPTS/cleanup.sh" --scan-path "$TMPDIR/scan.json" --log-path "$TMPDIR/cleanup.log" --rules "$SANDBOX/missing-rules.json" --ids npm-cache
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"No usable log path:"* ]]
}

write_dup_scan() {
  local group bytes paths_part sha first_path objects="" obj
  local paths=()
  for group in "$@"; do
    bytes="${group%%:*}"
    paths_part="${group#*:}"
    paths=()
    IFS='|' read -r -a paths <<<"$paths_part"
    first_path="${paths[0]}"
    sha="$(. "$SCRIPTS/common.sh" && dc_sha256 "$first_path")"
    obj="$(MSYS2_ARG_CONV_EXCL="*" jq -n -c --argjson b "$bytes" --arg s "$sha" '{bytes: $b, sha256: $s, paths: $ARGS.positional}' --args "${paths[@]}")"
    objects="$objects$obj"$'\n'
  done
  local groups_json
  groups_json="$(printf '%s' "$objects" | jq -s .)"
  MSYS2_ARG_CONV_EXCL="*" jq -n --arg t "$HOME" --argjson d "$groups_json" '{schemaVersion: 1, target: $t, home: $t, duplicates: $d}' > "$SANDBOX/out/scan.json"
}

seed_duplicates() {
  make_file "$HOME/Downloads/a.bin" 4096 202001010000
  make_file "$HOME/Desktop/a.bin" 4096 202101010000
  make_file "$HOME/Videos2/a.bin" 4096 202201010000
  make_file "$HOME/Documents/d1.bin" 8192 202001010000
  make_file "$HOME/Documents/d2.bin" 8192 202101010000
  make_file "$HOME/Backups/x.bak" 12288 202001010000
  make_file "$HOME/Backups/y.bak" 12288 202101010000
  make_file "$HOME/Data/x.mdf" 16384 202001010000
  make_file "$HOME/Data/y.mdf" 16384 202101010000
}

write_all_dup_groups() {
  write_dup_scan \
    "4096:$HOME/Downloads/a.bin|$HOME/Desktop/a.bin|$HOME/Videos2/a.bin" \
    "8192:$HOME/Documents/d1.bin|$HOME/Documents/d2.bin" \
    "12288:$HOME/Backups/x.bak|$HOME/Backups/y.bak" \
    "16384:$HOME/Data/x.mdf|$HOME/Data/y.mdf"
}

seed_extensions() {
  make_file "$HOME/.vscode/extensions/pub.ext-1.2.0/package.json" 100
  make_file "$HOME/.vscode/extensions/pub.ext-1.10.0/package.json" 100
  make_file "$HOME/.vscode/extensions/pub.other-0.1.0/package.json" 100
}

@test "R11 keeps the oldest copy and never deletes a protected copy" {
  seed_duplicates
  write_all_dup_groups
  run_cleanup --ids exact-duplicates
  [ "$status" -eq 0 ]
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Desktop/a.bin" ]
  [ ! -e "$HOME/Videos2/a.bin" ]
  [ -e "$HOME/Documents/d1.bin" ]
  [ -e "$HOME/Documents/d2.bin" ]
  [ -e "$HOME/Backups/x.bak" ]
  [ ! -e "$HOME/Backups/y.bak" ]
  [ -e "$HOME/Data/x.mdf" ]
  [ -e "$HOME/Data/y.mdf" ]
  [[ "$output" == *"done exact-duplicates: deleted 2 files, 16384 bytes, skipped 0"* ]]
}

@test "R5 dry run of dedupe deletes nothing" {
  seed_duplicates
  write_all_dup_groups
  local before
  before="$(tree_snapshot)"
  run_cleanup --dry-run --ids exact-duplicates
  [ "$(tree_snapshot)" = "$before" ]
  [[ "$output" == *"dry-run exact-duplicates: would free 16384 bytes"* ]]
}

@test "R11 skips a group whose copy changed after the scan" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  printf 'x' >> "$HOME/Videos2/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R11 never deletes a copy outside the scan target" {
  seed_duplicates
  make_file "$SANDBOX/outside/a.bin" 4096 202301010000
  write_dup_scan "4096:$HOME/Downloads/a.bin|$SANDBOX/outside/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$SANDBOX/outside/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R11 dedupe without a scan target is not applicable and deletes nothing" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  jq 'del(.target)' "$SANDBOX/out/scan.json" > "$SANDBOX/out/scan.notarget.json"
  mv "$SANDBOX/out/scan.notarget.json" "$SANDBOX/out/scan.json"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: no scan target"* ]]
}

@test "R4 never deletes a copy whose path climbs out of the target with dot dot" {
  make_file "$HOME/Downloads/a.bin" 4096 202001010000
  make_file "$SANDBOX/outside/a.bin" 4096 202301010000
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Downloads/../../outside/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$SANDBOX/outside/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R4 never deletes a critical file reached through a doubled slash" {
  make_file "$HOME/Downloads/c.bin" 4096 202001010000
  make_file "$HOME/.aws/credentials" 4096 202301010000
  write_dup_scan "4096:$HOME/Downloads/c.bin|$HOME//.aws/credentials"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/c.bin" ]
  [ -e "$HOME/.aws/credentials" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R4 never deletes a copy whose path has a dot segment or is relative" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/./Videos2/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
  write_dup_scan "4096:$HOME/Downloads/a.bin|Videos2/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R4 dedupe with a non canonical scan target is not applicable and deletes nothing" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  jq --arg t "$HOME/Downloads/.." '.target = $t' "$SANDBOX/out/scan.json" > "$SANDBOX/out/scan.nc.json"
  mv "$SANDBOX/out/scan.nc.json" "$SANDBOX/out/scan.json"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: no scan target"* ]]
}

@test "R11 never deletes a copy that is a symlink" {
  seed_duplicates
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Downloads/a.bin" "$HOME/Videos2/link.bin" || skip "symlinks not available"
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/link.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -L "$HOME/Videos2/link.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "R11 re-checks the guard on every copy before deleting" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Desktop/a.bin|$HOME/Videos2/a.bin"
  run bash -c '
    . "$SCRIPTS/cleanup.sh"
    platform=linux
    dry_run=no
    target="$HOME"
    scan_json="$SANDBOX/out/scan.json"
    all_rules="$(jq -c .rules "$RULES")"
    crit_paths="$(dc_critical_paths "$all_rules" "$platform")"
    crit_names="$(dc_critical_names "$all_rules" "$platform")"
    prot_paths="$crit_paths"
    prot_names="$crit_names"
    dc_dedupe_deletions() { printf "%s\n" "$HOME/Documents/d1.bin" "$HOME/Videos2/a.bin"; }
    rule="$(jq -c ".rules[] | select(.id == \"exact-duplicates\")" "$RULES")"
    run_dedupe_action "$rule"
  '
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Desktop/a.bin" ]
  [ ! -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"partial"*"skipped 1"* ]]
}

@test "dedupe is not applicable without scan.json" {
  seed_duplicates
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Desktop/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [ -e "$HOME/Backups/y.bak" ]
  [[ "$output" == *"not-applicable exact-duplicates: no scan.json"* ]]
}

@test "removes only older extension versions" {
  seed_extensions
  run_cleanup --ids ide-old-extensions
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.vscode/extensions/pub.ext-1.2.0" ]
  [ -e "$HOME/.vscode/extensions/pub.ext-1.10.0" ]
  [ -e "$HOME/.vscode/extensions/pub.other-0.1.0" ]
  [[ "$output" == *"done ide-old-extensions: deleted 1 files"* ]]
}

@test "R5 dry run of old-versions deletes nothing" {
  seed_extensions
  local before
  before="$(tree_snapshot)"
  run_cleanup --dry-run --ids ide-old-extensions
  [ "$(tree_snapshot)" = "$before" ]
  [[ "$output" == *"dry-run ide-old-extensions: would free"* ]]
}

@test "R8 old-versions keeps a critical subtree inside an old version" {
  seed_extensions
  make_file "$HOME/.vscode/extensions/pub.ext-1.2.0/.git/config" 10
  run_cleanup --ids ide-old-extensions
  [ -e "$HOME/.vscode/extensions/pub.ext-1.2.0/.git/config" ]
  [ ! -e "$HOME/.vscode/extensions/pub.ext-1.2.0/package.json" ]
}

@test "R8 old-versions refuses a matched root that is a symlink" {
  make_file "$HOME/elsewhere/pub.ext-1.2.0/package.json" 100
  make_file "$HOME/elsewhere/pub.ext-1.10.0/package.json" 100
  mkdir -p "$HOME/.vscode"
  MSYS=winsymlinks:nativestrict ln -s "$HOME/elsewhere" "$HOME/.vscode/extensions" || skip "symlinks not available"
  run_cleanup --ids ide-old-extensions
  [ -e "$HOME/elsewhere/pub.ext-1.2.0/package.json" ]
  [[ "$output" == *"refused ide-old-extensions: protected path "* ]]
}

@test "R8 old-versions re-checks the guard on every file before deleting" {
  seed_extensions
  make_file "$HOME/Documents/keep.txt" 10
  run bash -c '
    . "$SCRIPTS/cleanup.sh"
    platform=linux
    dry_run=no
    target="$HOME"
    all_rules="$(jq -c .rules "$RULES")"
    crit_paths="$(dc_critical_paths "$all_rules" "$platform")"
    crit_names="$(dc_critical_names "$all_rules" "$platform")"
    dc_list_files() { printf "%s\0" "$HOME/Documents/keep.txt" "$HOME/.vscode/extensions/pub.ext-1.2.0/package.json"; }
    rule="$(jq -c ".rules[] | select(.id == \"ide-old-extensions\")" "$RULES")"
    run_old_versions_action "$rule"
  '
  [ -e "$HOME/Documents/keep.txt" ]
  [ ! -e "$HOME/.vscode/extensions/pub.ext-1.2.0/package.json" ]
  [[ "$output" == *"partial"*"skipped 1"* ]]
}

@test "M1 refuses a matched path whose parent folder is a symlink" {
  make_file "$HOME/Documents/caches/important.txt" 10
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Documents" "$HOME/.gradle" || skip "symlinks not available"
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -e "$HOME/Documents/caches/important.txt" ]
  [[ "$output" == *"refused gradle-cache: protected path "* ]]
}

@test "M1 old-versions refuses a matched path whose parent folder is a symlink" {
  make_file "$HOME/elsewhere/extensions/pub.ext-1.2.0/package.json" 100
  make_file "$HOME/elsewhere/extensions/pub.ext-1.10.0/package.json" 100
  MSYS=winsymlinks:nativestrict ln -s "$HOME/elsewhere" "$HOME/.vscode" || skip "symlinks not available"
  run_cleanup --ids ide-old-extensions
  [ -e "$HOME/elsewhere/extensions/pub.ext-1.2.0/package.json" ]
  [[ "$output" == *"refused ide-old-extensions: protected path "* ]]
}

@test "M1 skips a dedupe copy whose parent folder is a symlink" {
  seed_duplicates
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Videos2" "$HOME/Linked" || skip "symlinks not available"
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Linked/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"not-applicable exact-duplicates: nothing matched"* ]]
}

@test "M2 write_log_line keeps seven columns when the detail holds a tab or newline" {
  local log="$SANDBOX/out/direct.log"
  run bash -c '
    . "$SCRIPTS/cleanup.sh"
    write_log_line "$1" id file refused 1 2 $'"'"'protected path a\tb\nc'"'"'
  ' _ "$log"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$log")" -eq 1 ]
  [ "$(awk -F '\t' '{print NF}' "$log")" -eq 7 ]
}

@test "M3 continues and writes the run end line when df fails" {
  make_file "$HOME/.npm/_cacache/x.bin" 10
  add_failing_stub df
  run_cleanup --ids npm-cache
  [ "$status" -eq 0 ]
  [[ "$output" == *"done npm-cache: exit 0"* ]]
  [ "$(awk -F '\t' '$2 == "-" && $4 == "end"' "$(log_file)" | wc -l)" -eq 1 ]
}

@test "M4 runs no before command when every matched path is refused" {
  make_file "$HOME/Documents/precious.txt" 10
  mkdir -p "$HOME/.gradle"
  MSYS=winsymlinks:nativestrict ln -s "$HOME/Documents" "$HOME/.gradle/caches" || skip "symlinks not available"
  run_cleanup --ids gradle-cache
  [ -e "$HOME/Documents/precious.txt" ]
  [[ "$output" == *"refused gradle-cache: protected path "* ]]
  [ -z "$(stub_calls)" ]
}

@test "I1 keeps a folder that was already empty and removes a folder the run emptied" {
  make_file "$HOME/.gradle/caches/a/b/c.bin" 10
  mkdir -p "$HOME/.gradle/caches/already-empty"
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -d "$HOME/.gradle/caches" ]
  [ -d "$HOME/.gradle/caches/already-empty" ]
  [ ! -e "$HOME/.gradle/caches/a" ]
}

@test "I1 never removes the rule root when the run empties it" {
  make_file "$HOME/.gradle/caches/only.bin" 10
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -d "$HOME/.gradle/caches" ]
}

@test "I1 keeps a folder that still holds a file the run skipped" {
  make_file "$HOME/.gradle/caches/mix/db.mdf" 10
  make_file "$HOME/.gradle/caches/mix/other.bin" 10
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -e "$HOME/.gradle/caches/mix/db.mdf" ]
  [ ! -e "$HOME/.gradle/caches/mix/other.bin" ]
}

@test "I3 a tool rule with match entries and no path under the scan target is not applicable" {
  make_file "$HOME/.npm/_cacache/x.bin" 10
  mkdir -p "$HOME/isolated"
  printf '{"schemaVersion":1,"target":"%s","duplicates":[]}\n' "$HOME/isolated" > "$SANDBOX/out/scan.json"
  run_cleanup --ids npm-cache
  [ "$status" -eq 0 ]
  [[ "$output" == *"not-applicable npm-cache: nothing matched"* ]]
  [ -z "$(stub_calls)" ]
}

@test "I3 a tool rule runs when a match entry exists under the scan target" {
  make_file "$HOME/.npm/_cacache/x.bin" 10
  printf '{"schemaVersion":1,"target":"%s","duplicates":[]}\n' "$HOME" > "$SANDBOX/out/scan.json"
  run_cleanup --ids npm-cache
  [ "$status" -eq 0 ]
  [[ "$output" == *"done npm-cache: exit 0"* ]]
  [[ "$(stub_calls)" == *"npm cache clean --force"* ]]
}

@test "I7 a step that exits nonzero does not end the run" {
  run bash -c "source \"$SCRIPTS/cleanup.sh\"; run_rule_action() { return 3; }; main --scan-path \"$SANDBOX/out/scan.json\" --log-path \"$SANDBOX/out/cleanup.log\" --ids gradle-cache,ide-old-extensions"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed gradle-cache: step error (exit 3)"* ]]
  [[ "$output" == *"failed ide-old-extensions: step error (exit 3)"* ]]
  [[ "$output" == *"Free space:"* ]]
  [ "$(awk -F '\t' '$2 == "-" && $3 == "run" && $4 == "end"' "$(log_file)" | wc -l)" -eq 1 ]
  [ "$(awk -F '\t' '$4 == "failed"' "$(log_file)" | wc -l)" -eq 2 ]
}

@test "m2 a hard link of the kept copy is not deleted and claims no bytes" {
  make_file "$HOME/Downloads/a.bin" 4096 202001010000
  mkdir -p "$HOME/Videos2" "$HOME/Music2"
  ln "$HOME/Downloads/a.bin" "$HOME/Videos2/a.bin"
  make_file "$HOME/Music2/a.bin" 4096 202201010000
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin|$HOME/Music2/a.bin"
  run_cleanup --ids exact-duplicates
  [ "$status" -eq 0 ]
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [ ! -e "$HOME/Music2/a.bin" ]
  [[ "$output" == *"done exact-duplicates: deleted 1 files, 4096 bytes, skipped 0"* ]]
}

@test "m2 two paths that are the same file delete nothing" {
  make_file "$HOME/Downloads/a.bin" 4096 202001010000
  mkdir -p "$HOME/Videos2"
  ln "$HOME/Downloads/a.bin" "$HOME/Videos2/a.bin"
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  run_cleanup --ids exact-duplicates
  [ "$status" -eq 0 ]
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"done exact-duplicates: deleted 0 files, 0 bytes, skipped 0"* ]]
}

@test "m3 a version folder that extensions.json references is never deleted" {
  seed_extensions
  printf '[{"identifier":{"id":"pub.ext"},"version":"1.2.0","location":{"path":"%s"},"relativeLocation":"pub.ext-1.2.0"}]\n' "$HOME/.vscode/extensions/pub.ext-1.2.0" > "$HOME/.vscode/extensions/extensions.json"
  run_cleanup --ids ide-old-extensions
  [ "$status" -eq 0 ]
  [ -e "$HOME/.vscode/extensions/pub.ext-1.2.0/package.json" ]
  [ -e "$HOME/.vscode/extensions/pub.ext-1.10.0/package.json" ]
}

@test "m9 a file symlink inside a cleared folder is skipped and its target is untouched" {
  make_file "$HOME/Documents/real.txt" 10
  mkdir -p "$HOME/.gradle/caches"
  ln -s "$HOME/Documents/real.txt" "$HOME/.gradle/caches/link.txt"
  if [ ! -L "$HOME/.gradle/caches/link.txt" ]; then
    skip "symlinks are not available in this shell"
  fi
  run_cleanup --ids gradle-cache
  [ "$status" -eq 0 ]
  [ -e "$HOME/Documents/real.txt" ]
  [ -L "$HOME/.gradle/caches/link.txt" ]
}

seed_credentials_group() {
  make_file "$HOME/Downloads/c.bin" 4096 202001010000
  make_file "$HOME/Videos2/c.bin" 4096 202201010000
  make_file "$HOME/.aws/credentials" 4096 202301010000
  write_dup_scan "4096:$HOME/Downloads/c.bin|$HOME/Videos2/c.bin|$HOME/.aws/credentials"
}

@test "R5 I1 a TMPDIR with a dot dot segment is ignored so credentials and documents survive" {
  make_file "$HOME/.aws/credentials" 4096 202001010000
  make_file "$HOME/Documents/thesis.docx" 4096 202001010000
  run_cleanup_env TMPDIR="$HOME/tmp/.." --ids user-temp
  [ "$status" -eq 0 ]
  [ -e "$HOME/.aws/credentials" ]
  [ -e "$HOME/Documents/thesis.docx" ]
  [[ "$output" == *"not-applicable user-temp: nothing matched"* ]]
}

@test "R5 I1 a relative TMPDIR is ignored" {
  make_file "$HOME/Documents/thesis.docx" 4096 202001010000
  run_cleanup_env TMPDIR="tmp" --ids user-temp
  [ "$status" -eq 0 ]
  [ -e "$HOME/Documents/thesis.docx" ]
  [[ "$output" == *"not-applicable user-temp: nothing matched"* ]]
}

@test "R5 I1 a TMPDIR with a doubled slash still clears old files" {
  make_file "$HOME/tmp/old.bin" 4096 202001010000
  run_cleanup_env TMPDIR="$HOME//tmp/" --ids user-temp
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/tmp/old.bin" ]
  [[ "$output" == *"done user-temp:"* ]]
}

@test "R5 I2 a HOME with a trailing slash is canonicalized: credentials survive and a plain copy is deleted" {
  seed_credentials_group
  run_cleanup_env HOME="$HOME/" --ids exact-duplicates
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX/home/.aws/credentials" ]
  [ -e "$SANDBOX/home/Downloads/c.bin" ]
  [ ! -e "$SANDBOX/home/Videos2/c.bin" ]
}

@test "R5 I2 a HOME with a dot segment exits 2 before any rule runs" {
  seed_credentials_group
  run_cleanup_env HOME="$SANDBOX/./home" --ids exact-duplicates
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid argument: HOME"* ]]
  [ -e "$SANDBOX/home/.aws/credentials" ]
  [ -e "$SANDBOX/home/Videos2/c.bin" ]
  [ ! -e "$SANDBOX/out/cleanup.log" ]
}

@test "R5 I2 a relative HOME exits 2" {
  run_cleanup_env HOME="home" --ids exact-duplicates
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid argument: HOME"* ]]
}

@test "R5 I3 on macos a case variant of a critical folder is still critical" {
  case "$(uname -s)" in
    Linux) skip "case variant path does not resolve on a case sensitive file system" ;;
  esac
  make_file "$HOME/Downloads/c.bin" 4096 202001010000
  make_file "$HOME/.aws/credentials" 4096 202301010000
  write_dup_scan "4096:$HOME/Downloads/c.bin|$HOME/.AWS/credentials"
  run_cleanup_env DISK_CLEANUP_PLATFORM=macos --ids exact-duplicates
  [ -e "$HOME/.aws/credentials" ]
  [ -e "$HOME/Downloads/c.bin" ]
}

@test "R5 a critical path that is not canonical refuses every deleting step" {
  local fixture
  fixture="$(fixture_rules $'.rules += [{"id":"fixture-crit","tier":"critical","platforms":["linux","macos"],"match":{"linux":["${HOME}/x/../y"],"macos":["${HOME}/x/../y"]},"action":null,"needsAdmin":false,"description":"x","reason":"x"}]')"
  make_file "$HOME/.npm/_cacache/old.bin" 4096 202001010000
  run_cleanup --rules "$fixture" --ids npm-cache
  [ "$status" -eq 0 ]
  [ -e "$HOME/.npm/_cacache/old.bin" ]
  [[ "$output" == *"refused npm-cache: invalid critical path $HOME/x/../y"* ]]
  [ -z "$(stub_calls)" ]
}

@test "R5 guarded_delete refuses a candidate that is not canonical" {
  make_file "$HOME/Downloads/a.bin" 10
  run bash -c '. "$1"; guarded_delete "$2" "" ""' _ "$SCRIPTS/cleanup.sh" "$HOME/Downloads/../Downloads/a.bin"
  [ "$status" -eq 1 ]
  [ -e "$HOME/Downloads/a.bin" ]
}

@test "R6 I1 a HOME that is not an existing directory exits 2 and credentials survive" {
  seed_credentials_group
  run_cleanup_env HOME="$HOME " --ids exact-duplicates
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid argument: HOME"* ]]
  [ -e "$SANDBOX/home/.aws/credentials" ]
  [ -e "$SANDBOX/home/Downloads/c.bin" ]
  [ -e "$SANDBOX/home/Videos2/c.bin" ]
}

@test "R6 m1 a scan made for the current home deletes the plain copy" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ ! -e "$HOME/Videos2/a.bin" ]
}

@test "R6 m1 a scan made for another home refuses the exact duplicates step" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  jq --arg h "$SANDBOX/elsewhere" '.home = $h' "$SANDBOX/out/scan.json" > "$SANDBOX/out/scan.home.json"
  mv "$SANDBOX/out/scan.home.json" "$SANDBOX/out/scan.json"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"refused exact-duplicates: scan made for another home"* ]]
}

@test "R6 m1 a scan without a home refuses the exact duplicates step" {
  seed_duplicates
  write_dup_scan "4096:$HOME/Downloads/a.bin|$HOME/Videos2/a.bin"
  jq 'del(.home)' "$SANDBOX/out/scan.json" > "$SANDBOX/out/scan.home.json"
  mv "$SANDBOX/out/scan.home.json" "$SANDBOX/out/scan.json"
  run_cleanup --ids exact-duplicates
  [ -e "$HOME/Downloads/a.bin" ]
  [ -e "$HOME/Videos2/a.bin" ]
  [[ "$output" == *"refused exact-duplicates: scan made for another home"* ]]
}

@test "R6 m2 a clear-dir root that contains HOME deletes nothing under HOME" {
  mkdir -p "$SANDBOX/h/home"
  make_file "$SANDBOX/h/home/Downloads/old.bin" 4096 202001010000
  make_file "$SANDBOX/h/home/.bashrc" 4096 202001010000
  run env HOME="$SANDBOX/h/home" TMPDIR="$SANDBOX/h" bash "$SCRIPTS/cleanup.sh" --scan-path "$SANDBOX/out/scan.json" --log-path "$SANDBOX/out/cleanup.log" --ids user-temp
  [ -e "$SANDBOX/h/home/Downloads/old.bin" ]
  [ -e "$SANDBOX/h/home/.bashrc" ]
}
