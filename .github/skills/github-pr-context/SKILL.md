---
name: github-pr-context
description: Fetch GitHub PR metadata, changed files, commits, and comments as a reusable review context bundle. Use when the user wants GitHub context only, wants to inspect PR metadata before review writing, or needs a standalone capability step inside the larger PR review workflow.
---

# GitHub PR Context

Use this skill only for the GitHub context stage.

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Use the PowerShell script directly from the current host:

```powershell
& .\.github\skills\github-pr-context\scripts\github_pr_context.ps1 -PrUrl "<pr-url>" -Mode auto
```

The output is a JSON bundle containing `pr_url`, `pull`, `files`, `commits`, `issue_comments`, and `review_comments`.
