# disk-cleanup

[![CI](https://github.com/ahmed-essawy/disk-cleanup/actions/workflows/ci.yml/badge.svg)](https://github.com/ahmed-essawy/disk-cleanup/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/ahmed-essawy/disk-cleanup)](LICENSE) [![Release](https://img.shields.io/github/v/release/ahmed-essawy/disk-cleanup)](https://github.com/ahmed-essawy/disk-cleanup/releases)

disk-cleanup is an Agent Skill that finds what is using disk space and frees it safely. It works in Claude Code and in any other AI coding agent that can run shell commands on your computer, such as Codex CLI, Gemini CLI, GitHub Copilot, Cursor, Windsurf, Cline, OpenCode and Antigravity. The agent scans a drive read-only, shows one checklist in three tiers, and deletes only the items you tick. Critical items can never be deleted.

> Screenshot placeholder: the checklist with its Safe, Your call and Critical groups.

## Safety first

Scanning is read-only, and nothing is deleted before you submit the checklist.

| Tier | In the checklist | Examples | Can be deleted |
|---|---|---|---|
| Safe | ticked | user Temp files older than 1 day, package caches (NuGet, npm, Yarn, pip, Gradle, Maven), crash dumps, oversized logs | yes |
| Your call | unticked | Docker dangling images and build cache, old VS Code extensions, Android system images, Chrome on-device model, old Claude Code session logs, old installers, exact duplicates (the oldest copy stays) | yes, when you tick it |
| Critical | disabled | databases, backups, VM disks, Docker volumes, system folders, Program Files, mail stores, Documents, Desktop, Pictures, cloud sync folders, source code, credentials | never |

On macOS and Linux the user Temp folder is `$TMPDIR`, outside `$HOME`, so `user-temp` is offered only when that folder is the scan target or under it.

Read the full model in [docs/safety-model.md](docs/safety-model.md).

## Requirements

- An AI coding agent with a real shell on the computer you want to clean (file system and command access). Claude Code works, and so does every agent under Install.
- Windows 10 or 11 with Windows PowerShell 5.1 or PowerShell 7.
- macOS 14+ or Linux with bash and `jq` (built in on macOS 15 and later; `brew install jq`, `sudo apt install jq`, `sudo dnf install jq`).

### Why not ChatGPT, Gemini or claude.ai on the web?

The skill runs native commands (robocopy, du, find, package manager clean commands) on the machine that owns the disk. Chat-only apps (claude.ai, ChatGPT and Gemini on the web or on mobile) and cloud agents or sandboxes have no shell on your computer, so anything they run happens on a remote server. The skill detects this and stops with a message asking you to open a local AI coding agent on that computer.

### Agents that sandbox commands

Some agents run commands in a sandbox limited to the current workspace (Codex and Antigravity by default, Cursor when its sandbox is on). The scan reads the whole drive and the cleanup deletes caches outside the workspace, so approve these commands to run outside the sandbox when the agent asks. Otherwise they fail with access errors.

## Install

Every agent below loads Agent Skills, a folder with a `SKILL.md` file. Installing means copying `skills/disk-cleanup` into the agent's personal skills folder. The folders come from each agent's official docs (checked November 2026), linked in each section.

Clone the repo once:

Windows (PowerShell):

```powershell
git clone https://github.com/ahmed-essawy/disk-cleanup.git "$env:TEMP\disk-cleanup"
```

macOS and Linux:

```bash
git clone https://github.com/ahmed-essawy/disk-cleanup.git /tmp/disk-cleanup
```

| Agent | Personal skills folder | Docs |
|---|---|---|
| Claude Code | `~/.claude/skills/` | [Claude Code skills](https://code.claude.com/docs/en/skills) |
| OpenAI Codex CLI | `~/.agents/skills/` | [Codex skills](https://learn.chatgpt.com/docs/build-skills) |
| Gemini CLI | `~/.gemini/skills/` | [Gemini CLI skills](https://geminicli.com/docs/cli/skills/) |
| GitHub Copilot (VS Code agent mode and Copilot CLI) | `~/.copilot/skills/` | [VS Code agent skills](https://code.visualstudio.com/docs/copilot/customization/agent-skills) |
| Cursor | `~/.cursor/skills/` | [Cursor skills](https://cursor.com/docs/context/skills) |
| Windsurf (Devin Desktop) | `~/.agents/skills/` | [Devin Desktop skills](https://docs.devin.ai/desktop/cascade/skills) |
| Cline | `~/.cline/skills/` | [Cline skills](https://docs.cline.bot/features/skills) |
| OpenCode | `~/.agents/skills/` | [OpenCode skills](https://opencode.ai/docs/skills/) |
| Google Antigravity | `~/.gemini/config/skills/` | [Antigravity skills](https://antigravity.google/docs/skills) |

Tip: one copy in ~/.agents/skills is read by Codex CLI, Gemini CLI, GitHub Copilot CLI, Cursor, Windsurf (Devin Desktop) and OpenCode.
On Windows, ~ is your user folder ($HOME in PowerShell).

### Claude Code

Personal skills folder: ~/.claude/skills/. Docs: [skills](https://code.claude.com/docs/en/skills), [plugins](https://code.claude.com/docs/en/discover-plugins).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.claude\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.claude/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.claude/skills/
```

Or install it as a plugin. Inside Claude Code:

```
/plugin marketplace add ahmed-essawy/disk-cleanup
/plugin install disk-cleanup@disk-cleanup
```

From a terminal:

```bash
claude plugin marketplace add ahmed-essawy/disk-cleanup
claude plugin install disk-cleanup@disk-cleanup
```

The copied skill is `/disk-cleanup`, the plugin skill is `/disk-cleanup:disk-cleanup`, and both also start from a matching request.

### OpenAI Codex CLI

Personal skills folder: ~/.agents/skills/. Docs: [Codex skills](https://learn.chatgpt.com/docs/build-skills).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.agents\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.agents/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.agents/skills/
```

### Gemini CLI

Personal skills folder: ~/.gemini/skills/. Docs: [Gemini CLI skills](https://geminicli.com/docs/cli/skills/), [transition to Antigravity CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.gemini\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.gemini\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.gemini/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.gemini/skills/
```

On June 18, 2026 Google replaced Gemini CLI with Antigravity CLI for free, Google One and AI Pro or Ultra users. It still runs with paid Gemini API keys and Gemini Code Assist Standard or Enterprise. Antigravity users follow [Google Antigravity](#google-antigravity).

### GitHub Copilot (VS Code agent mode and Copilot CLI)

Personal skills folder: ~/.copilot/skills/. Docs: [VS Code agent skills](https://code.visualstudio.com/docs/copilot/customization/agent-skills), [Copilot CLI skills](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.copilot\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.copilot\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.copilot/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.copilot/skills/
```

VS Code agent mode and Copilot CLI both read ~/.copilot/skills.

### Cursor

Personal skills folder: ~/.cursor/skills/. Docs: [Cursor skills](https://cursor.com/docs/context/skills).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.cursor\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.cursor\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.cursor/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.cursor/skills/
```

### Windsurf (Devin Desktop)

Personal skills folder: ~/.agents/skills/. Docs: [Devin Desktop skills](https://docs.devin.ai/desktop/cascade/skills), [Devin Desktop FAQ](https://docs.devin.ai/desktop/devin-desktop-faq).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.agents\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.agents/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.agents/skills/
```

Windsurf is now Devin Desktop; its skills docs list ~/.agents/skills as a global skills folder.

### Cline

Personal skills folder: ~/.cline/skills/. Docs: [Cline skills](https://docs.cline.bot/features/skills).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.cline\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.cline\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.cline/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.cline/skills/
```

### OpenCode

Personal skills folder: ~/.agents/skills/. Docs: [OpenCode skills](https://opencode.ai/docs/skills/).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.agents\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.agents/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.agents/skills/
```

### Google Antigravity

Personal skills folder: ~/.gemini/config/skills/. Docs: [Antigravity skills](https://antigravity.google/docs/skills).

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.gemini\config\skills" | Out-Null; Copy-Item -Recurse -Force "$env:TEMP\disk-cleanup\skills\disk-cleanup" "$HOME\.gemini\config\skills\"
```

macOS and Linux:

```bash
mkdir -p ~/.gemini/config/skills && cp -R /tmp/disk-cleanup/skills/disk-cleanup ~/.gemini/config/skills/
```

### Any other agent with a local shell

Copy `skills/disk-cleanup` to any folder in your home folder, then add one line to that agent's own instructions or rules file:

```
When I ask to free disk space, read and follow <absolute path>/disk-cleanup/SKILL.md; its scripts are in the scripts folder next to it.
```

Restart the agent or start a new session so it loads the skill.

## How to use

### Example prompts

- "free up space on C:"
- "what's eating my disk?"
- "disk full, clean my home folder"

In Claude Code you can also type `/disk-cleanup`.

### What happens, step by step

1. Gate: the agent checks it has a shell on this computer and stops with a message when it does not.
2. Partition: it uses the drive or folder you named, or asks you one question listing your drives.
3. Read-only scan: it writes `scan.json` and changes nothing else, with one status line `Scan complete: ...`.
4. Checklist: it classifies every finding with `rules.json` and shows one checklist.
5. Cleanup: only after you submit, it runs only the ticked ids, refuses Critical and unknown ids, skips steps that need admin rights when the shell is not elevated and tells you how to rerun them.
6. Result: one line `Free space: X GB -> Y GB (freed Z GB)` plus the skipped and refused lines when present.

### The checklist

The checklist has three tiles (Free now, Selected to free, Free after) and three groups: Safe (ticked), Your call (unticked) and Critical (disabled, with a short reason). The buttons are Clean selected, Reset to recommended and Clear all. Agents without an interactive widget show a table instead, and you reply with numbers or `ok`.

| # | Item | Size | Tier | Default |
|---|---|---|---|---|
| 1 | npm cache | 2.0 GB | Safe | ticked |
| 2 | Gradle caches | 4.0 GB | Safe | ticked |
| 3 | Docker build cache | 6.0 GB | Your call | unticked |
| 4 | Database data and log files | 10.0 GB | Critical | cannot be ticked |

### Dry run

Cleanup called with no ids is a dry run over the Safe ids for your OS. `-DryRun` (Windows) or `--dry-run` (macOS, Linux) reports what each step would do and deletes nothing. The summary line is `Dry run: nothing deleted. Would free about X GB.`

### Where files go

| File | Windows | macOS and Linux |
|---|---|---|
| `scan.json` | `<drive>:\tmp\diskscan\scan.json` | `~/diskscan/scan.json` |
| `cleanup.log` | next to `scan.json` | next to `scan.json` |

The scan refuses an output folder inside a Temp folder, and a log path inside Temp falls back to the default. Change them with `-OutputDir` / `--output-dir` and `-LogPath` / `--log-path`. When you change the output folder, run cleanup with `-ScanPath` / `--scan-path` pointing at the new `scan.json`, because cleanup looks for it in the default folder.

### Run the scripts without an agent

From the cloned repo, on Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File ./skills/disk-cleanup/scripts/scan.ps1 -Target C:/
powershell -NoProfile -ExecutionPolicy Bypass -File ./skills/disk-cleanup/scripts/cleanup.ps1 -Ids npm-cache,gradle-cache -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File ./skills/disk-cleanup/scripts/cleanup.ps1 -Ids npm-cache,gradle-cache
```

On macOS and Linux:

```
bash skills/disk-cleanup/scripts/scan.sh --target "$HOME"
bash skills/disk-cleanup/scripts/cleanup.sh --ids npm-cache,gradle-cache --dry-run
bash skills/disk-cleanup/scripts/cleanup.sh --ids npm-cache,gradle-cache
```

Rule ids are in `skills/disk-cleanup/rules/rules.json` and in `scan.json` under `rules` with their sizes. Always run the dry run first. Every parameter is in [docs/how-it-works.md](docs/how-it-works.md).

## Add or override rules

Rules live in `skills/disk-cleanup/rules/rules.json`. To change behavior, edit that file in your own copy or fork; there is no separate override file. A Critical rule can never be made deletable, because Critical rules have no action and the scripts refuse Critical ids even when passed by hand. See [docs/adding-rules.md](docs/adding-rules.md).

## FAQ

### Which AI agents does it work with?

Any AI coding agent whose shell runs on your computer. Install steps for the common ones are under [Install](#install).

### Will it delete my files?

Only the items you tick, and only Safe and Your call items. Scanning never deletes, and Critical items are refused.

### Why does my agent ask for permission to run the scan?

The scan and cleanup run commands on your machine, some of them outside the workspace. Approve them; see [Agents that sandbox commands](#agents-that-sandbox-commands).

### Why do some items need admin rights?

Windows Update cache cleanup, component cleanup and Docker disk compaction need an elevated shell. When the shell is not elevated those steps are skipped and the result tells you to rerun from a terminal started with "Run as administrator". The scripts never elevate themselves.

### Where does it write its files?

`scan.json` and `cleanup.log` go to the output folder shown under [Where files go](#where-files-go), never inside a Temp folder.

### Why is an item I want to delete Critical?

Anything the rules mark Critical, and anything no rule covers, is Critical because deleting it could lose data or break the system. See [docs/safety-model.md](docs/safety-model.md).

### Can I recover what it deleted?

No. Files are deleted directly, not moved to the Recycle Bin or Trash. Safe items are caches that tools rebuild.

### Why does macOS and Linux need jq?

The bash scripts read `rules.json` and write `scan.json` with `jq`, so they stop with an install hint when it is missing.

### Does it follow symlinks or junctions?

No. Folder links, junctions and symlinks are never followed or deleted, and a file symlink inside a cleared folder is skipped, so neither the link nor its target is touched.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report rules that could delete user data through [SECURITY.md](SECURITY.md). Everyone taking part follows the [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

MIT, see [LICENSE](LICENSE).
