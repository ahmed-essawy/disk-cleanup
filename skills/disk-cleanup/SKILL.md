---
name: disk-cleanup
description: Scan a drive or folder for what is using disk space, show one Safe, Your call and Critical checklist, then clean only the items the user ticks. Use when the user says "free up space", "disk full", "clean C:" or "what's eating my disk". Needs an AI coding agent with a shell on the machine that owns the disk.
---

# Disk cleanup

Find what is using disk space, let the user tick what to clean, and clean only that.

Keep chat output minimal: a one-line status while working, the checklist, and a one-line result.

Script paths: every script command below starts with the skill folder variable that Claude Code fills in. In any other agent, replace that prefix with the absolute path of the folder that holds this SKILL.md (the scripts are in its scripts/ subfolder).

## 0. Environment gate

Requirement: a shell tool whose commands run natively on the computer that owns the disk, whatever the agent.

Check: run `$PSVersionTable.PSVersion` on Windows, `uname -s` on macOS and Linux.

Stop when there is no shell tool, the check fails, or the result shows the shell runs somewhere else (for example uname -s prints Linux while the user asked to clean drive C:). Chat-only apps (claude.ai, ChatGPT or Gemini on the web, mobile apps) and cloud or remote sandboxes cannot run this skill.

If the agent runs commands in a sandbox limited to the workspace, ask the user once to allow the scan and cleanup commands to run outside it.

When stopping, reply only with this message:

> This skill has to run on the computer you want to clean. Open a local AI coding agent on that machine (Claude Code, or another agent that can run shell commands there) and run it there. It needs a local shell to scan and clean the disk.

Do not take over the screen and do not ask the user to run scripts by hand as a workaround.

## 1. Pick the partition

Use the drive or path the user named. Otherwise list the volumes (`Get-PSDrive -PSProvider FileSystem` on Windows, `df -h` on macOS and Linux) and ask one question, with the agent's question tool when it has one. Do nothing else before scanning.

## 2. Scan (read-only)

Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/scan.ps1" -Target <drive>:/
```

macOS and Linux (or the path the user named instead of `$HOME`):

```
bash "${CLAUDE_SKILL_DIR}/scripts/scan.sh" --target "$HOME"
```

- Output: `%LOCALAPPDATA%\diskscan\scan.json` on Windows, `${XDG_CACHE_HOME:-$HOME/.cache}/diskscan/scan.json` on macOS and Linux (a per-user folder, never inside a Temp folder). The scripts refuse a scan folder or scan.json that is a link, is owned by someone else or, on macOS and Linux, is writable by others.
- macOS and Linux need `jq`. When the script exits 5, show its install hint in one line and stop.
- The scan is read-only and prints one `Scan complete: ...` line.

## 3. Classify

Read `scan.json`. Checklist rows are the `rules` entries with `available` true and `bytes` above 0, plus the entries with `available` true and `bytes` null (rules whose action type is `tool` or `compact-docker-vhdx`), grouped by `tier`. Add up to 10 of the largest `folders` and `largeFiles` whose `tier` is `critical` as disabled rows. Anything no rule covers is Critical. The rules are in [rules.json](rules/rules.json). When unsure about an item, it is Critical.

## 4. Checklist

Show one inline interactive checklist when a widget is available, following [the checklist template](assets/checklist.html):

- three tiles: free now, selected to free, free after;
- groups: Safe (ticked), Your call (unticked), Critical (disabled checkbox with a short reason such as "database", "system", "user data");
- buttons: "Clean selected", "Reset to recommended", "Clear all".

"Clean selected" sends `Clean these ids: <id>,<id>`.

Fallback without a widget: a markdown table with the columns `#`, `Item`, `Size`, `Tier`, `Default`, then the line "Reply with the numbers to clean, for example `1,2,5`, or `ok` for the recommended set." Add no prose around it beyond one line.

## 5. Clean (only after the user submits)

Delete nothing before the user submits. Run only the submitted ids and never add ids.

Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/cleanup.ps1" -Ids <id1>,<id2>
```

macOS and Linux:

```
bash "${CLAUDE_SKILL_DIR}/scripts/cleanup.sh" --ids <id1>,<id2>
```

- The scripts refuse Critical and unknown ids. Report refused ids in one line.
- Steps that need admin are skipped when the shell is not elevated. Say how to rerun elevated. Never try to get around UAC and never use sudo.
- The log is `cleanup.log`, next to `scan.json`.

## 6. Result

Final reply is one line: `Free space: X GB → Y GB (freed Z GB)`, built from the script's summary line (which prints `->`). Add the skipped and refused lines when present.
