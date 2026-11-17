---
name: New rule
about: Propose a new Safe, Your call or Critical rule
title: "rule: "
labels: rule
---

## Proposed rule

```json
{
  "id": "example-tool-cache",
  "tier": "safe",
  "platforms": ["windows", "linux"],
  "match": {
    "windows": ["${LOCALAPPDATA}/ExampleTool/Cache"],
    "linux": ["${HOME}/.cache/exampletool"]
  },
  "action": {
    "type": "delete-files",
    "include": ["*"],
    "recurse": true,
    "minSizeMB": 0,
    "olderThanDays": 7
  },
  "needsAdmin": false,
  "description": "Example tool cache older than 7 days",
  "reason": "The tool rebuilds this cache on next start."
}
```

## Operating systems

List the systems the rule applies to: Windows, macOS, Linux.

## Evidence the data is regenerable

Explain how the owning tool rebuilds it, and link to its documentation.

## Why this tier

Say why the rule belongs in Safe, Your call or Critical.

## Risk

Describe what a user could lose if the rule deletes the wrong thing.
