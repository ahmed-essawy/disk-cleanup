sandbox_setup() {
  umask 022
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SANDBOX="$BATS_TEST_DIRNAME/.sandbox/$(date +%s)$$$RANDOM"
  mkdir -p "${SANDBOX}/home/tmp" "${SANDBOX}/bin"
  ( umask 077 && mkdir -p "${SANDBOX}/out" )
  export SANDBOX
  export REPO_ROOT
  export SCRIPTS="$REPO_ROOT/skills/disk-cleanup/scripts"
  export RULES="$REPO_ROOT/skills/disk-cleanup/rules/rules.json"
  export HOME="$SANDBOX/home"
  export TMPDIR="${SANDBOX}/home/tmp"
  export XDG_CACHE_HOME="$HOME/.cache"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export PATH="$SANDBOX/bin:$PATH"
  export DISK_CLEANUP_FORCE_NOT_ELEVATED=1
  export DISK_CLEANUP_STUB_LOG="$SANDBOX/stub.log"
  case "$(uname -s)" in
    Darwin|Linux) ;;
    *) export DISK_CLEANUP_PLATFORM=linux ;;
  esac
  add_tool_stubs
}

sandbox_teardown() {
  case "${SANDBOX:-}" in
    */.sandbox/*) rm -rf -- "$SANDBOX" ;;
  esac
}

_write_stub() {
  local name="${1%$'\r'}"
  local code="$2"
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/$name"
  printf 'printf "%%s %%s\\n" "%s(basename \"%s0\")" "%s*" >>"%s"\n' '$' '$' '$' "$DISK_CLEANUP_STUB_LOG" >> "$SANDBOX/bin/$name"
  printf 'exit %d\n' "$code" >> "$SANDBOX/bin/$name"
  chmod +x "$SANDBOX/bin/$name"
}

add_tool_stubs() {
  local name
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [ -n "$name" ] && _write_stub "$name" 0
  done < <(jq -r '.rules[] | (.action.command? // empty), (.before[]?.command)' "$RULES" 2>/dev/null)
  for name in sudo wsl diskpart runas; do
    _write_stub "$name" 0
  done
}

add_failing_stub() {
  _write_stub "$1" 1
}

make_file() {
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/zero > "$1"
  if [ -n "${3:-}" ]; then
    touch -t "$3" "$1"
  fi
}

tree_snapshot() {
  local fmt
  if stat -c %s / >/dev/null 2>&1; then
    fmt=(-c '%n|%s|%Y')
  else
    fmt=(-f '%N|%z|%m')
  fi
  find "$SANDBOX" \( -path "$SANDBOX/out" -o -path "$SANDBOX/stub.log" \) -prune -o -print0 | xargs -0 stat ${fmt[@]+"${fmt[@]}"} | LC_ALL=C sort
}

stub_calls() {
  cat "$DISK_CLEANUP_STUB_LOG" 2>/dev/null || true
}

fixture_rules() {
  jq "$1" "$RULES" > "$SANDBOX/rules.json"
  printf '%s\n' "$SANDBOX/rules.json"
}
