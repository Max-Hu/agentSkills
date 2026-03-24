---
name: pr-review-writer
description: Turn a combined GitHub and Jira evidence bundle into a structured review report and editable Markdown draft. Use when the user already has normalized PR/Jira evidence, wants only the writing stage, or wants to regenerate the draft without refetching external data.
---

# PR Review Writer

Use this skill when the evidence bundle already exists and the remaining task is analysis plus draft generation.

Use the script that matches the user's system:

```powershell
.github/skills/pr-review-writer/scripts/pr_review_writer.ps1 -InputPath "<combined-bundle.json>" -OutputFormat json -DraftPath "pr-review-drafts\pr-<number>-review.md"
```

```bash
.github/skills/pr-review-writer/scripts/pr_review_writer.sh --input "<combined-bundle.json>" --output json --draft-path "pr-review-drafts/pr-<number>-review.md"
```

Bash mode expects `node` to be available.

Return the report JSON and draft metadata, or the Markdown review if the user explicitly wants Markdown only.
