# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-17

### Added

- Agent skill `disk-cleanup` for Claude Code and any AI coding agent with a local shell, with an environment gate, a read-only scan and one checklist.
- `rules.json` with Safe, Your call and Critical tiers. Exact duplicates are in Your call: the oldest copy stays and copies in protected folders are never deleted.
- `scan.ps1` and `cleanup.ps1` for Windows PowerShell 5.1 and PowerShell 7.
- `scan.sh` and `cleanup.sh` for macOS and Linux.
- Critical ids are refused in code.
- Dry run by default when no ids are given.
- `scan.json` records the home folder it was made for, and cleanup refuses the duplicates step for a scan made for another home.
- Scan and cleanup exit with code 2 when `HOME` or `USERPROFILE` is not a canonical existing folder.
- The scan file lives in a per-user folder outside Temp, `%LOCALAPPDATA%\diskscan` on Windows and `${XDG_CACHE_HOME:-$HOME/.cache}/diskscan` on macOS and Linux. Scan and cleanup refuse a scan folder or scan file that is a link, is owned by someone else or, on macOS and Linux, is writable by others, and cleanup never deletes inside the scan folder.
- Docker disk compaction runs `diskpart /s` on a script file created with `CreateNew` inside the trust-checked per-user scan folder and deleted after the step.
- Sandboxed Pester and bats suites.
- Plugin and marketplace manifests.
- CI on Windows, Ubuntu and macOS.

[1.0.0]: https://github.com/ahmed-essawy/disk-cleanup/releases/tag/v1.0.0
