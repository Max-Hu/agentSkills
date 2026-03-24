---
name: github-pr-context
description: Fetch and normalize GitHub pull request context as JSON, including PR metadata, changed files, commits, issue comments, and review comments. Use when the user only wants the GitHub evidence stage, wants to inspect the raw PR bundle, or when a larger review workflow needs a dedicated GitHub context worker.
---

# GitHub PR Context

Use this skill when only the GitHub PR evidence is needed.

Use the script that matches the user's system:

```powershell
.github/skills/github-pr-context/scripts/github_pr_context.ps1 -PrUrl "<pr-url>" -Mode auto
```

```bash
.github/skills/github-pr-context/scripts/github_pr_context.sh --pr-url "<pr-url>" --mode auto
```

Bash mode expects `node` and `curl` to be available.

Return the JSON bundle. Do not write the final review in this skill.
