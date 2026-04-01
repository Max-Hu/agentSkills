---
name: pr-review-writer
description: Turn a combined GitHub and Jira evidence bundle into a structured review report and editable Markdown draft. The current expert implementation is Java-focused and runs through a dedicated Java analyzer module without changing the stable writer entrypoint.
---

# PR Review Writer

Use this skill when the evidence bundle already exists and the remaining task is review analysis plus draft generation.

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Use the PowerShell script directly from the current host:

```powershell
& .\.github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath "<combined-bundle.json>" -OutputFormat json -DraftPath "pr-review-drafts\pr-<number>-review.md"
```

Current active expert reviewer: `Senior Java/Spring Reviewer`.
Current code review mode: `java-expert-diff`.
The code-level review is limited to Java ecosystem files such as `.java`, Spring configuration, runtime resource config, build config, and logging config.
The stable writer entrypoint stays generic; the Java expert implementation is highlighted under `scripts/analyzers/java/java_expert_analyzer.ps1`.
The writer is diff-based only and does not use AST, Maven/Gradle compilation, or external Java tooling.

Return the report JSON and draft metadata, or the Markdown review if the user explicitly wants Markdown only.
