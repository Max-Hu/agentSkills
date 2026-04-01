---
name: jira-issue-context
description: Resolve Jira issue context for a GitHub PR by extracting keys from PR metadata and loading issue details plus comments. Use when the user wants Jira context only, wants to check PR-to-Jira alignment before full review, or needs a standalone Jira evidence step inside the larger PR review workflow.
---

# Jira Issue Context

Use this skill only for the Jira context stage.

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Use the PowerShell script directly from the current host:

```powershell
& .\.github\skills\jira-issue-context\scripts\jira_issue_context.ps1 -InputPath "<github-bundle.json>" -Mode auto
```

The output is a JSON bundle containing `jira_keys` and `jira_issues`.
