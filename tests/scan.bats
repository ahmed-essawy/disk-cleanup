#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  sandbox_setup
  SCAN="$SANDBOX/out/scan.json"
}

teardown() {
  sandbox_teardown
}

run_scan() {
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES"
}

@test "writes only scan.json inside the output folder" {
  make_file "$HOME/a.txt" 10
  make_file "$HOME/.npm/_cacache/x.bin" 1024
  local before
  before="$(tree_snapshot)"
  run_scan
  [ "$status" -eq 0 ]
  local after
  after="$(tree_snapshot)"
  [ "$after" = "$before" ]
  run ls -A "$SANDBOX/out"
  [ "$output" = "scan.json" ]
}

@test "refuses an output folder inside Temp with exit 3" {
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$TMPDIR/out" --rules "$RULES"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"Output folder refused:"* ]]
  [ ! -e "$TMPDIR/out" ]
}

@test "lists a 2 MiB file with --min-file-mb 1" {
  make_file "$HOME/big/one.bin" 2097152
  run_scan
  [ "$status" -eq 0 ]
  local bytes
  bytes="$(jq -r '.largeFiles[] | select(.path | endswith("/big/one.bin")) | .bytes' "$SCAN")"
  [ "$bytes" = "2097152" ]
}

@test "lists two identical 2 MiB files as one duplicate group" {
  make_file "$HOME/a/f.bin" 2097152
  make_file "$HOME/b/f.bin" 2097152
  run_scan
  [ "$status" -eq 0 ]
  local count paths_count sha
  count="$(jq '.duplicates | length' "$SCAN")"
  paths_count="$(jq '.duplicates[0].paths | length' "$SCAN")"
  sha="$(jq -r '.duplicates[0].sha256' "$SCAN")"
  [ "$count" -eq 1 ]
  [ "$paths_count" -eq 2 ]
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
}

@test "emits every top-level key with the right types" {
  run_scan
  [ "$status" -eq 0 ]
  jq -e '(.schemaVersion == 1) and (.createdAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and (.os | IN("macos","linux")) and (.target | type == "string") and (.minFileBytes == 1048576) and (.drive | (.root | type == "string") and (.totalBytes | type == "number") and (.usedBytes | type == "number") and (.freeBytes | type == "number")) and (.rules | type == "array") and (.folders | type == "array") and (.largeFiles | type == "array") and (.duplicates | type == "array") and (.unreadable | type == "array")' "$SCAN"
}

@test "keeps one-element arrays as arrays" {
  make_file "$HOME/big/one.bin" 2097152
  run_scan
  [ "$status" -eq 0 ]
  jq -e '(.largeFiles | type == "array" and length == 1) and (.duplicates == [])' "$SCAN"
}

@test "a seeded npm cache is available with bytes above zero" {
  make_file "$HOME/.npm/_cacache/x.bin" 4096
  run_scan
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "npm-cache") | .available == true and .bytes > 0' "$SCAN"
}

@test "a folder under Documents is critical" {
  make_file "$HOME/Documents/d.txt" 10
  run_scan
  [ "$status" -eq 0 ]
  local tier rids
  tier="$(jq -r --arg p "$HOME/Documents" '.folders[] | select(.path == $p) | .tier' "$SCAN")"
  rids="$(jq -r --arg p "$HOME/Documents" '.folders[] | select(.path == $p) | .ruleIds[]' "$SCAN")"
  [ "$tier" = "critical" ]
  [[ "$rids" == *"user-folders"* ]]
}

@test "a folder no rule covers is critical" {
  make_file "$HOME/Unrelated/u.txt" 10
  run_scan
  [ "$status" -eq 0 ]
  local tier count
  tier="$(jq -r --arg p "$HOME/Unrelated" '.folders[] | select(.path == $p) | .tier' "$SCAN")"
  count="$(jq --arg p "$HOME/Unrelated" '.folders[] | select(.path == $p) | .ruleIds | length' "$SCAN")"
  [ "$tier" = "critical" ]
  [ "$count" -eq 0 ]
}

@test "a gradle cache folder is safe with its clear-dir rule id" {
  make_file "$HOME/.gradle/caches/c.bin" 1024
  run_scan
  [ "$status" -eq 0 ]
  local tier rids
  tier="$(jq -r --arg p "$HOME/.gradle/caches" '.folders[] | select(.path == $p) | .tier' "$SCAN")"
  rids="$(jq -c --arg p "$HOME/.gradle/caches" '.folders[] | select(.path == $p) | .ruleIds' "$SCAN")"
  [ "$tier" = "safe" ]
  [ "$rids" = '["gradle-cache"]' ]
}

@test "rules lists every platform rule in file order" {
  run_scan
  [ "$status" -eq 0 ]
  local scan_ids rule_ids
  scan_ids="$(jq -c '[.rules[].id]' "$SCAN")"
  rule_ids="$(jq -c --arg p "$(jq -r .os "$SCAN")" '[.rules[] | select(.platforms | index($p)) | .id]' "$RULES")"
  [ "$scan_ids" = "$rule_ids" ]
}

@test "tool rules without match entries have null bytes" {
  run_scan
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "docker-dangling-images") | .bytes == null' "$SCAN"
}

@test "prints the scan complete line" {
  run_scan
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^Scan\ complete:\ .*/out/scan\.json\ \([0-9]+\ folders,\ [0-9]+\ large\ files,\ [0-9]+\ duplicate\ groups,\ [0-9]+\ unreadable\)$ ]]
}

@test "a missing target exits 2" {
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME/nope" --output-dir "$SANDBOX/out" --rules "$RULES"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid argument:"* ]]
  run ls -A "$SANDBOX/out"
  [ -z "$output" ]
}

@test "an invalid min-file-mb exits 2" {
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --min-file-mb 0 --rules "$RULES"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid argument:"* ]]
}

@test "an invalid rules file exits 4" {
  mkdir -p "$SANDBOX"
  printf '{' > "$SANDBOX/bad.json"
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --rules "$SANDBOX/bad.json"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"Rules file invalid:"* ]]
}

@test "help exits 0 and prints the options" {
  run bash "$SCRIPTS/scan.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--min-file-mb"* ]]
}

@test "I3 a tool rule with match entries but no path under the target is unavailable with zero bytes" {
  make_file "$HOME/.npm/_cacache/x.bin" 1024
  make_file "$HOME/isolated/a.txt" 10
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME/isolated" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES"
  [ "$status" -eq 0 ]
  jq -e '[.rules[] | select(.id == "npm-cache" or .id == "nuget-cache" or .id == "yarn-cache" or .id == "pip-cache") | select(.available == false and .bytes == 0)] | length == 4' "$SCAN"
}

@test "I3 a tool rule without match entries keeps null bytes and availability" {
  make_file "$HOME/isolated/a.txt" 10
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME/isolated" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES"
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "docker-dangling-images") | .available == true and .bytes == null' "$SCAN"
}

@test "I4 a folder list larger than 64 KB still gives exit 0 and a valid scan.json" {
  local i name
  name="$(printf 'd%.0s' $(seq 1 80))"
  mkdir -p "$HOME/many"
  for i in $(seq 1 1200); do
    mkdir "$HOME/many/${name}_$i"
  done
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES"
  [ "$status" -eq 0 ]
  jq -e '(.folders | length) == 100' "$SCAN"
}

@test "I4 an unreadable subfolder under a rule root still gives exit 0 and a valid scan.json" {
  mkdir -p "$HOME/.cache/locked/inner"
  make_file "$HOME/.cache/locked/inner/a.bin" 10
  make_file "$HOME/.cache/open/b.bin" 10
  chmod 000 "$HOME/.cache/locked"
  if [ "$(id -u)" -eq 0 ] || ls "$HOME/.cache/locked" >/dev/null 2>&1; then
    chmod 755 "$HOME/.cache/locked"
    skip "chmod 000 has no effect here (root or Git Bash)"
  fi
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES"
  chmod 755 "$HOME/.cache/locked"
  [ "$status" -eq 0 ]
  jq -e '.schemaVersion == 1 and (.unreadable | length) >= 1' "$SCAN"
}

@test "m2 hard linked copies claim no reclaimable bytes" {
  make_file "$HOME/Downloads/a.bin" 2097152
  mkdir -p "$HOME/Videos2"
  ln "$HOME/Downloads/a.bin" "$HOME/Videos2/a.bin"
  run_scan
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "exact-duplicates") | .bytes == 0' "$SCAN"
}

@test "m2 a real copy next to a hard link claims bytes once" {
  make_file "$HOME/Downloads/a.bin" 2097152 202001010000
  mkdir -p "$HOME/Videos2" "$HOME/Music2"
  ln "$HOME/Downloads/a.bin" "$HOME/Videos2/a.bin"
  make_file "$HOME/Music2/a.bin" 2097152 202201010000
  run_scan
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "exact-duplicates") | .bytes == 2097152' "$SCAN"
}

run_scan_env() {
  local assignment="$1"
  shift
  run --separate-stderr env "$assignment" bash "$SCRIPTS/scan.sh" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$RULES" "$@"
}

@test "R5 a HOME with a dot segment exits 2 and writes nothing" {
  run_scan_env HOME="$SANDBOX/./home" --target "$HOME"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "Invalid argument: HOME"* ]]
  [ ! -e "$SCAN" ]
}

@test "R5 a HOME with a trailing slash is canonicalized and scans normally" {
  make_file "$HOME/.npm/_cacache/x.bin" 1024
  run_scan_env HOME="$HOME/"
  [ "$status" -eq 0 ]
  jq -e --arg h "$HOME" '.target == $h' "$SCAN"
  jq -e '.rules[] | select(.id == "npm-cache") | .available == true' "$SCAN"
}

@test "R5 a TMPDIR with a dot dot segment makes user-temp unavailable" {
  make_file "$HOME/Documents/thesis.docx" 1024 202001010000
  run_scan_env TMPDIR="$HOME/tmp/.." --target "$HOME"
  [ "$status" -eq 0 ]
  jq -e '.rules[] | select(.id == "user-temp") | (.available == false and (.paths | length) == 0)' "$SCAN"
}

@test "R5 a critical path that is not canonical marks every deleting rule unavailable" {
  local fixture
  fixture="$(fixture_rules $'.rules += [{"id":"fixture-crit","tier":"critical","platforms":["linux","macos"],"match":{"linux":["${HOME}/x/../y"],"macos":["${HOME}/x/../y"]},"action":null,"needsAdmin":false,"description":"x","reason":"x"}]')"
  make_file "$HOME/.npm/_cacache/x.bin" 1024
  make_file "$HOME/.cache/y.bin" 2097152
  run --separate-stderr bash "$SCRIPTS/scan.sh" --target "$HOME" --output-dir "$SANDBOX/out" --min-file-mb 1 --rules "$fixture"
  [ "$status" -eq 0 ]
  jq -e '[.rules[] | select(.tier != "critical") | .available] | all(. == false)' "$SCAN"
}

@test "R6 I1 a HOME that is not an existing directory exits 2 and writes nothing" {
  run_scan_env HOME="$HOME " --target "$HOME"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "Invalid argument: HOME"* ]]
  [ ! -e "$SCAN" ]
}

@test "R6 m1 scan.json records the canonical home" {
  run_scan_env HOME="$HOME/"
  [ "$status" -eq 0 ]
  jq -e --arg h "$HOME" '.home == $h' "$SCAN"
}
