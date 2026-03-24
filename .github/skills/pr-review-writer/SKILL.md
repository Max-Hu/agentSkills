---
name: pr-review-writer
description: Turn a combined GitHub and Jira evidence bundle into a structured review report and editable Markdown draft. Use when the user already has normalized PR/Jira evidence, wants only the writing stage, or wants to regenerate the draft without refetching external data.
---

# PR Review Writer

Use this skill when the evidence bundle already exists and the remaining task is analysis plus draft generation.

Run:

```powershell
python .github/skills/pr-review-writer/scripts/pr_review_writer.py --input "<combined-bundle.json>" --output json --draft-path "pr-review-drafts\pr-<number>-review.md"
```

Return the report JSON and draft metadata, or the Markdown review if the user explicitly wants Markdown only.
