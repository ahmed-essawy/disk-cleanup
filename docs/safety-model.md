# Safety model

## The three tiers

| Tier | Default in the checklist | Meaning |
|---|---|---|
| Safe | ticked | caches and leftovers that tools rebuild: user Temp files older than 1 day, package caches, crash dumps, oversized logs, Windows Update cache |
| Your call | unticked | useful to free but you decide: Docker images and build cache, old VS Code extensions, Android system images, Chrome on-device model, old Claude Code session logs, old installers, exact duplicates (the oldest copy stays) |
| Critical | disabled | data or system files that must never be deleted: databases, backups, VM disks, Docker volumes, system folders, Program Files, mail stores, Documents, Desktop, Pictures, cloud sync folders, source code, credentials |

Scanning is read-only. Nothing is deleted before you submit the checklist, and only the ticked ids are sent to cleanup.

## Why Critical can never be deleted

- Critical rules have `action: null`. There is nothing to run for them.
- The cleanup scripts check the tier before they read the action. A Critical id is refused even when it is passed by hand, and even when an edited rules file gives a Critical rule an action.
- An unknown id is refused.
- Anything no rule covers is shown as Critical, so a new or unusual folder is never offered for deletion.

## The deletion guard

Every action that deletes paths (`clear-dir`, `delete-files`, `old-versions` and `dedupe`) passes each target path through one guard:

1. The path is refused when it is a volume root, equals the home folder, or is equal to or under any Critical path.
2. The cleanup never descends into or deletes a Critical path under the target, a path with a segment that matches a Critical name pattern (for example `.git`, or files such as `*.mdf` and `*.pst`), or a junction or symlink. Folder links and junctions are never followed or deleted, and a file symlink inside a cleared folder is skipped, so neither the link nor its target is touched.

A refused path is logged as `refused` with `protected path <path>` and does not stop the other paths of the step.

Before each delete on Windows, cleanup checks the listed path again: it must still exist, be a file and not a link, sit under the rule root, match the include patterns and still meet the size and age filters. After deleting, it removes only the folders that became empty because of the run, walking up from each deleted file and stopping at the rule root, which is never removed. Folders that were already empty are left alone.

Tool actions and Docker compaction do not delete paths directly. They are protected by their tier, by the admin requirement and by your explicit selection.

On Windows the Critical system entries are specific subfolders (System32, WinSxS, Installer and others) instead of the whole Windows folder, so the Safe Windows Update cache stays reachable. The Windows folder itself is still shown as Critical, because anything no rule covers is Critical.

## Admin steps

Three rules need an elevated shell: `windows-update-cache`, `dism-component-cleanup` and `docker-wsl-compact`.

- When the shell is not elevated, these steps are skipped and logged as `skipped`.
- The hint on Windows is `rerun from a terminal started with "Run as administrator"`. On macOS and Linux it is `rerun the cleanup script as root yourself`.
- No script calls `sudo` or `runas`, starts a process with `-Verb RunAs`, or changes UAC. You rerun the step yourself.
- `DISK_CLEANUP_FORCE_NOT_ELEVATED=1` treats the shell as not elevated. It can only lower privilege, never raise it.

## Temp folders

The scan and cleanup exit with code 2 when `HOME` (macOS and Linux) or `USERPROFILE` (Windows) is not a canonical path to an existing folder, because every home-relative rule and guard depends on it. On macOS and Linux a `TMPDIR` that is not a canonical absolute path is ignored with a notice.

The scan refuses an output folder inside a Temp folder, and cleanup falls back to the default when the log path is inside Temp. If the default log path is also inside Temp or cannot be created, cleanup exits with code 3. The Temp folders are Windows `TEMP`, `TMP`, `%LOCALAPPDATA%\Temp` and `%SystemRoot%\Temp`, and on macOS and Linux `TMPDIR`, `/tmp`, `/var/tmp`, `/private/tmp` and `/private/var/folders`.

## Scan folder

The scan file steers what cleanup deletes, so it lives in a per-user folder outside Temp: `%LOCALAPPDATA%\diskscan` on Windows and `${XDG_CACHE_HOME:-$HOME/.cache}/diskscan` on macOS and Linux. Scan and cleanup exit with code 3 when the scan folder or `scan.json` is a link or reparse point, is not owned by the current user (on Windows `BUILTIN\Administrators` also counts), or on macOS and Linux is writable by group or others. A missing folder is created readable only by the user. Cleanup never deletes anything inside the scan folder, even when a rule such as `app-logs-oversized` matches a parent folder.

Compacting a Docker disk runs `diskpart /s` elevated on a script file that exists only for that step. The file is created with `FileMode.CreateNew` (the step fails if the name is taken) inside the per-user scan folder, which is checked first and never trusted when it is a link or owned by someone else, is written as ASCII, is opened with `FileShare.Read` only while it is written and is deleted in a `finally` block.

## Duplicates

- The scan groups large files by size, then compares SHA-256. Groups of two or more identical files are listed under `duplicates`.
- Exact duplicates are a Your call item, so they are unticked by default.
- `scan.json` records the home folder it was made for. Cleanup refuses the duplicates step with `scan made for another home` when that home is missing or differs from the current one, and reports `no scan target` when the scan target is missing.
- On Windows, a path with an 8.3 short-name segment (for example `PROGRA~1`) is never trusted: such a copy is not deleted, such a scan target gives `no scan target`, and a Critical path that cannot be expanded to its long name refuses the whole step with `unresolved critical path <path>`.
- Before deleting, cleanup checks the size and hash of each copy again. Changed copies are dropped, and a group left with fewer than two copies is skipped.
- It keeps the copy with the oldest last-write time (ties go to the first path in ordinal order) and deletes the other copies that are under the scan target and not protected.
- A copy is protected when it matches a Critical rule, for example a copy in Documents, Desktop or a source code folder. When every copy is protected, nothing is deleted.
- Two paths that are the same file (hard links) count as one file: neither is deleted and no bytes are claimed for them.
- The one exception is the `database-backups` rule (`.bak` files), which allows duplicate removal: of two identical `.bak` files the newer is deleted. Identical `.mdf` files are both kept.

## Deviation from the original skill

User Temp is cleaned with an age floor on every OS: only files older than 1 day are deleted, instead of all contents. On macOS and Linux nothing is locked, so deleting fresh temp files can break running apps. The 1-day floor keeps one rule for all platforms.

On macOS and Linux the user Temp folder is the one named by `$TMPDIR`, which is outside `$HOME` (the rule has no `/tmp` fallback, so on Linux with `TMPDIR` unset it is not matched at all). The scan and cleanup only touch paths under the scan target, so `user-temp` is offered there only when that Temp folder is the target or sits under it.
