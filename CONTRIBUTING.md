# Contributing

Thank you for helping. This project deletes files on real machines, so safety comes before features.

## Setup

Windows:

- Pester 5.7.1
- PSScriptAnalyzer 1.25.0
- Git Bash
- shellcheck
- jq
- bats-core v1.11.0

macOS and Linux:

- bash
- jq
- shellcheck
- bats-core

## Run the checks

```
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path skills -Recurse -Settings PSScriptAnalyzerSettings.psd1 -EnableExit"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path tests -Recurse -Settings PSScriptAnalyzerSettings.psd1 -EnableExit"
pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester tests -CI"
powershell -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester tests -CI"
shellcheck skills/disk-cleanup/scripts/*.sh tests/*.bats tests/*.bash
bash "$BATS" tests
node -e "JSON.parse(require('fs').readFileSync('skills/disk-cleanup/rules/rules.json'))"
claude plugin validate .
```

## Test rules

- Tests run only in the sandbox under `tests/.sandbox`.
- Never touch a real user folder.
- Never run a real tool or Docker.
- Never need admin rights.

## Safety review

Every pull request completes the checklist in the pull request template. Moving a rule out of Critical, adding an action, or touching refusal logic needs a safety review note in the pull request.

## Commit messages

Use Conventional Commits, imperative mood, with a lower case subject. Example:

```
feat(rules): add rules.json with safe, your_call and critical tiers
```

## Style

- No code comments.
- No em or en dash in any text.
- PowerShell files are ASCII only.
- Bash code is Bash 3.2 compatible.
