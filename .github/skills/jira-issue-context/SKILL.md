---
name: jira-issue-context
description: Extract Jira keys from a PR bundle and fetch Jira issue context as JSON. Use when the user wants Jira intent only, wants to inspect the linked Jira issues, or when a larger review workflow needs a dedicated Jira context worker.
---

# Jira Issue Context

Use this skill after GitHub PR context is available.

Use the PowerShell script:

```powershell
.github/skills/jira-issue-context/scripts/jira_issue_context.ps1 -InputPath "<github-bundle.json>" -Mode auto
```

Return the JSON Jira bundle. Do not write the final review in this skill.
