## Summary

## Changes

## Safety review

- [ ] The tier of every new or changed rule is justified in this PR.
- [ ] No Critical rule was changed, or the change is explained with a safety review note.
- [ ] The Critical refusal tests pass on Windows, Linux and macOS.
- [ ] Tests run only in the sandbox; no real user folder, tool or Docker command is used.
- [ ] No personal or company data is added.

## Checks

- [ ] PSScriptAnalyzer
- [ ] Pester (pwsh and powershell)
- [ ] shellcheck
- [ ] bats
- [ ] `claude plugin validate .`
