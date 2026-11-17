# How it works

## The flow

Any AI coding agent with a shell on your computer runs the same flow:

1. Gate: the agent checks that it has a shell on this computer and stops with a message when it does not.
2. Partition: it uses the drive or folder you named, or asks you one question listing your drives.
3. Scan: `scan.ps1` (Windows) or `scan.sh` (macOS and Linux) measures the target read-only and writes `scan.json`.
4. Classify: every finding is matched against `skills/disk-cleanup/rules/rules.json` and gets a tier: Safe, Your call or Critical.
5. Checklist: the agent shows one checklist. Safe items are ticked, Your call items are unticked and Critical items are disabled.
6. Cleanup: after you submit, `cleanup.ps1` or `cleanup.sh` runs only the ticked rule ids.
7. Result: the agent prints the free space before and after, plus any skipped and refused items.

## Scan

Windows (Windows PowerShell 5.1 and PowerShell 7):

```
powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1 [-Target <string>] [-OutputDir <string>] [-MinFileMB <int>] [-RulesPath <string>]
```

macOS and Linux (bash with `jq`):

```
scan.sh [--target <path>] [--output-dir <path>] [--min-file-mb <n>] [--rules <path>] [--help]
```

| Parameter (Windows / macOS and Linux) | Default | Meaning |
|---|---|---|
| `-Target` / `--target` | `$env:SystemDrive\` / `$HOME` | folder or drive root to scan; it must exist |
| `-OutputDir` / `--output-dir` | `<qualifier of Target>\tmp\diskscan` / `$HOME/diskscan` | folder that receives `scan.json` |
| `-MinFileMB` / `--min-file-mb` | 500 | size from which a file is listed as a large file, integer from 1 to 1048576 |
| `-RulesPath` / `--rules` | `rules/rules.json` next to the scripts | rules file to use |

`-ExecutionPolicy Bypass` applies to that one process only. It is not an elevation or UAC bypass.

The scan is read-only. It writes only inside the output folder: `scan.json`, plus temporary work files that it removes at the end. It never deletes, moves or renames anything, never changes attributes or timestamps, and never runs a rule's tool command.

- Windows sizes folders and lists files with robocopy in list mode (`/L`), which copies nothing. Junctions are not followed.
- macOS and Linux use `du` and `find` limited to one file system (`du -x`, `find -xdev`). Symlinks are not followed.
- Rule paths are only sized when they are under the scan target.
- The scan refuses an output folder inside a Temp folder: Windows `TEMP`, `TMP`, `%LOCALAPPDATA%\Temp` and `%SystemRoot%\Temp`; macOS and Linux `TMPDIR`, `/tmp`, `/var/tmp`, `/private/tmp` and `/private/var/folders`.

On success the scan prints one line:

```
Scan complete: <full path of scan.json> (<n> folders, <m> large files, <k> duplicate groups, <u> unreadable)
```

| Exit code | Meaning | stderr |
|---|---|---|
| 0 | `scan.json` written (also when some folders were unreadable) | none |
| 2 | invalid argument, target missing, `HOME` or `USERPROFILE` not a canonical existing folder, unsupported OS | `Invalid argument: <detail>` or `Unsupported OS: <name>` |
| 3 | output folder inside Temp, or it cannot be created | `Output folder refused: <path> is inside a Temp folder` or `Cannot create output folder: <path>` |
| 4 | rules file missing or not valid JSON, or a rule lacks `id` or `tier` | `Rules file invalid: <path>` |
| 5 | missing dependency (macOS and Linux: `jq`) | an install hint |

`scan.ps1` with a non-integer `-MinFileMB` stops in PowerShell parameter binding with exit 1 before the script runs. Only out-of-range integers get exit 2.

## scan.json

`<OutputDir>/scan.json` has the same shape from both scan scripts. Byte counts are integers, times are UTC ISO 8601, and paths are native to the OS.

| Key | Meaning |
|---|---|
| `schemaVersion` | always 1 |
| `createdAt` | UTC time of the scan |
| `os` | `windows`, `macos` or `linux` |
| `target` | full path of the scanned target |
| `home` | canonical home folder (`USERPROFILE` or `HOME`) the scan was made for; cleanup refuses the `dedupe` step when it is missing or differs from the current home (case-insensitive on Windows and macOS) |
| `minFileBytes` | the large file threshold in bytes |
| `drive` | `root`, `totalBytes`, `usedBytes` and `freeBytes` of the target's volume |
| `rules` | every rule for this OS in `rules.json` order, with `id`, `tier`, `available`, `bytes` and `paths` |
| `folders` | the 100 largest folders, biggest first, each with `path`, `bytes`, `tier` and `ruleIds` |
| `largeFiles` | every file at or above `minFileBytes`, biggest first, each with `path`, `bytes`, `modified`, `tier` and `ruleIds` |
| `duplicates` | groups of two or more large files with the same size and SHA-256, each with `bytes`, `sha256` and `paths` |
| `unreadable` | folders the scan could not read; the scan still completes |

Notes on `rules[]`:

- `available` is true when a tool rule's command is on PATH and, if the rule has match entries, at least one of them exists under the target (`dism-component-cleanup` also needs the target on the system drive), when a `dedupe` rule has duplicates, and otherwise when at least one expanded path exists under the target.
- `bytes` is what the action would free under the target. It is `0` for a tool rule with match entries but no path under the target, `null` for a tool rule with no match entries and always `null` for `compact-docker-vhdx`, because the reclaimable size is unknown.

A folder or file has tier `critical` when a Critical rule matches it or when no rule covers it. Otherwise it is `your_call` if any matched rule is `your_call`, else `safe`.

## Cleanup

Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File cleanup.ps1 [-Ids <string[]>] [-DryRun] [-LogPath <string>] [-ScanPath <string>] [-RulesPath <string>]
```

macOS and Linux:

```
cleanup.sh [--ids <a,b,c>] [--dry-run] [--log-path <path>] [--scan-path <path>] [--rules <path>] [--help]
```

| Parameter (Windows / macOS and Linux) | Default | Meaning |
|---|---|---|
| `-Ids` / `--ids` | none | rule ids to run; a comma list is accepted |
| `-DryRun` / `--dry-run` | off | report what each step would do and delete nothing |
| `-LogPath` / `--log-path` | `cleanup.log` in the folder of the scan file | log file |
| `-ScanPath` / `--scan-path` | `$env:SystemDrive\tmp\diskscan\scan.json` / `$HOME/diskscan/scan.json` | scan file to read |
| `-RulesPath` / `--rules` | `rules/rules.json` next to the scripts | rules file to use |

Ids are trimmed, split on commas, emptied of blanks and de-duplicated. With no ids, cleanup runs a dry run over every Safe rule for the current OS, even without `-DryRun`.

Each requested id is decided in this order:

1. Unknown id: `refused` (unknown id).
2. Critical tier: `refused` (critical).
3. No action: `refused` (no action).
4. Rule for another OS: `not-applicable`.
5. Needs admin and the shell is not elevated: `skipped`.
6. Tool command or required program missing: `not-applicable`.
7. Dry run: `dry-run` with the estimated bytes.
8. Otherwise the step runs.

The Critical check comes before the action check, so a hand-edited rules file that gives a Critical rule an action is still refused. Steps run in `rules.json` order, not in the order given.

If the log path is inside a Temp folder, cleanup prints `Log path refused (inside Temp), using <default>` to stderr and uses the default log path.

Every step prints one line, `<result> <id>: <detail>`. A real run then prints:

```
Free space: 120.4 GB -> 131.9 GB (freed 11.5 GB)
Skipped (needs admin): windows-update-cache, dism-component-cleanup. Rerun from a terminal started with "Run as administrator".
Refused: database-files (critical), foo (unknown id)
```

A dry run prints:

```
Dry run: nothing deleted. Would free about 11.5 GB.
Skipped (needs admin): ...
Refused: ...
```

The `Skipped` and `Refused` lines appear only when they are not empty. On macOS and Linux the hint is `Rerun the cleanup script as root yourself.`

| Exit code | Meaning |
|---|---|
| 0 | no step failed (refused, skipped, not-applicable and dry-run steps are not failures) |
| 1 | at least one step `failed` |
| 2 | invalid argument, `HOME` or `USERPROFILE` not a canonical existing folder, or unsupported OS |
| 3 | no usable log path (`No usable log path: <path>`) |
| 4 | rules file missing or invalid |
| 5 | missing dependency (macOS and Linux: `jq`) |

A PowerShell parameter-binding error, for example a value that is not a string array, is raised by PowerShell before the script runs and exits 1.

Two environment variables exist:

| Variable | Effect |
|---|---|
| `DISK_CLEANUP_FORCE_NOT_ELEVATED=1` | treat the shell as not elevated; it can only lower privilege |
| `DISK_CLEANUP_PLATFORM` | bash only: `macos` or `linux`, used when `uname -s` is neither |

## cleanup.log

The log is appended on every run. It is UTF-8, with LF line endings on macOS and Linux and CRLF on Windows. Each line has 7 tab-separated columns:

```
<timestamp UTC>  <id>  <action type>  <result>  <free bytes before>  <free bytes after>  <detail>
```

- The first line of a run has id `-`, action `run`, result `start` and detail `dryRun=<true|false> ids=<comma list>`.
- One line follows per requested id (and per Safe id in the no-ids dry run).
- The last line of a run has id `-`, action `run`, result `end`, the free space at the start and at the end, and detail `failed=<n>`.

| Result | Meaning |
|---|---|
| `done` | the step ran |
| `partial` | some files were locked or skipped |
| `dry-run` | dry run, nothing deleted |
| `skipped` | needs admin and the shell is not elevated |
| `refused` | unknown id, Critical id, no action, a protected path, a scan made for another home, or an unresolved Critical path for `dedupe` (Windows) |
| `not-applicable` | other OS, tool missing, nothing matched, or no `scan.json` or no scan target for `dedupe` |
| `failed` | a tool exited with a non-zero code, compaction failed, or the step raised an error (the message is the detail and the run continues with the next id) |

The detail is one line without tabs: `would free <bytes> bytes` for `dry-run`, `deleted <n> files, <bytes> bytes, skipped <n>` for `done` and `partial`, `exit 0` for tools, `unknown id`, `critical`, `no action`, `protected path <path>`, `scan made for another home` or `unresolved critical path <path>` for `refused`, `needs admin: <hint>` for `skipped`, and for `failed` the error message (PowerShell) or `step error (exit <n>)` (bash).
