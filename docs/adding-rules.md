# Adding rules

All rules live in `skills/disk-cleanup/rules/rules.json`: UTF-8 without BOM, 2-space indent, shaped as `{ "version": 1, "rules": [ ... ] }`. The scripts read this one file for every OS. The current catalog in that file is the reference for every field below.

## Rule fields

| Field | Type | Required | Rules |
|---|---|---|---|
| `id` | string | yes | kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`), unique |
| `tier` | string | yes | `safe`, `your_call` or `critical` |
| `platforms` | string[] | yes | non-empty subset of `windows`, `macos`, `linux`, no repeats |
| `match` | object | yes | keys exactly equal to `platforms`; each value is an array of entries (may be empty) |
| `action` | object or null | yes | `null` if and only if `tier` is `critical` |
| `needsAdmin` | boolean | yes | `false` on every critical rule |
| `description` | string | yes | short row label, 1 to 80 characters, no em or en dash |
| `reason` | string | yes | why this tier, 1 to 200 characters |
| `before` | command[] | no | non-critical rules only; run before the action, failures are logged and ignored |
| `allowDuplicateRemoval` | boolean | no | critical rules only; `true` only on `database-backups` |

A command is `{ "command": "<executable name, no path>", "args": ["..."] }`.

## Action types

| `type` | Extra fields | Meaning |
|---|---|---|
| `tool` | `command`, `args` | run the tool; match paths are only used for sizing; a missing tool gives `not-applicable` |
| `clear-dir` | none | delete the contents of each matched folder (not the folder), guarded |
| `delete-files` | `include` (name globs), `recurse` (bool), `minSizeMB` (int, 0 or more), `olderThanDays` (int, 0 or more) | delete matching files under each matched folder, guarded, then remove emptied subfolders |
| `old-versions` | none | in each matched folder, delete the subfolders of every extension except the highest version |
| `dedupe` | none | take duplicate groups from `scan.json`, keep the oldest copy, never delete protected copies |
| `compact-docker-vhdx` | none | Windows only: stop Docker Desktop, run `wsl --shutdown`, compact each matched vhdx with `diskpart`, then start Docker Desktop again when it was running before |

For `old-versions`, a folder name must look like `<name>-<version>` (for example `publisher.extension-1.2.0`). Only the highest version per name is kept, and names that do not match the pattern are kept. A version folder that `extensions.json` in the matched folder references (by `relativeLocation` or the last part of `location.path`) is never deleted.

## Path tokens and name patterns

- A match entry is a string. Use `${NAME}` tokens and `/` as the separator on every OS; PowerShell converts to `\` after expansion.
- Tokens read the process environment only. Windows tokens in use: `USERPROFILE`, `LOCALAPPDATA`, `APPDATA`, `TEMP`, `ProgramData`, `ProgramFiles`, `ProgramFiles(x86)`, `SystemRoot`, `SystemDrive`, `OneDrive`, `OneDriveCommercial`. macOS and Linux tokens: `HOME`, `TMPDIR`.
- If any token in an entry is unset or empty, the whole entry is dropped. An unset variable can never collapse a path to a root.
- `*` and `?` are wildcards and are allowed in any segment.
- An entry that starts with `**/` is a name pattern, not a path. It matches any path that has a segment matching the rest (for example `**/*.mdf` or `**/.git`), case-insensitively. Name patterns are allowed only in Critical rules.
- Entries never contain a user name, a drive letter, `~`, a backslash or `..`. Every Windows entry starts with `${` or `**/`. Absolute Unix entries such as `/usr` or `/var/lib/mysql` are allowed only in `macos` and `linux` arrays.

## Choosing a tier

- Safe: a cache or leftover that its tool rebuilds, with no user data inside.
- Your call: useful to free, but the user should decide because something may be lost or slow to rebuild.
- Critical: anything that could hold user data or that the system needs. When unsure, choose Critical.

A Critical rule has `action: null` and `needsAdmin: false`. Any new Safe or Your call rule that deletes paths needs a safety review: what can the path contain, can a user keep data there, and does the deletion guard protect everything that must survive. The pull request template asks for this review.

## Tests to run

Run these from the repo root before you open a pull request:

```
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path skills -Recurse -Settings PSScriptAnalyzerSettings.psd1 -EnableExit"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path tests -Recurse -Settings PSScriptAnalyzerSettings.psd1 -EnableExit"
pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester tests -CI"
powershell -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester tests -CI"
shellcheck skills/disk-cleanup/scripts/*.sh tests/*.bats tests/*.bash
bats tests
node -e "JSON.parse(require('fs').readFileSync('skills/disk-cleanup/rules/rules.json'))"
```

The first four run PSScriptAnalyzer and the Pester suite on PowerShell 7 and on Windows PowerShell 5.1. The last three run shellcheck, the bats suite (bats-core 1.11) and a JSON parse of `rules.json`.

## Overriding a rule in your copy

Edit `rules.json` in your own copy or fork. There is no override file and no config file.

A Critical rule cannot be made deletable. It has no action, the scripts refuse Critical ids before they read an action, and `tests/rules.Tests.ps1` fails for a Critical rule that has an action.
