# PR Jira Review Usage Guide

## 1. Purpose

`pr-jira-review` is the orchestrator skill for this review workflow:

1. collect GitHub PR context
2. collect Jira issue context
3. write an evidence-backed review report and editable Markdown draft
4. optionally publish or update the review as a managed PR comment

The sibling skills are:

- `github-pr-context`
- `jira-issue-context`
- `pr-review-writer`
- `pr-review-publisher`

## 2. Current Expert Module

The public skill entrypoints remain generic.
The current active expert reviewer is `Senior Java/Spring Reviewer` in `java-expert-diff` mode.
The Java expert implementation is highlighted under `scripts/analyzers/java/`, and the orchestrator reuses that Java analyzer path through the writer entrypoint.

## 3. PowerShell Compatibility

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Examples below invoke the `.ps1` files directly so the current PowerShell host controls execution without requiring a specific executable name.

## 4. Default Usage

For normal usage, call only the orchestrator:

```text
Use $pr-jira-review to audit this PR:
https://github.com/acme/payments-service/pull/123
```

The orchestrator should:

- choose `mock`, `real`, or `auto`
- decide whether subagents are worth using
- return the structured report
- write an editable Markdown draft
- expose the publish target for later comment publishing

## 5. Orchestrator Command

PowerShell:

```powershell
& .\.github\skills\pr-jira-review\scripts\review_pr.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -Mode auto -OutputFormat json -DraftPath "pr-review-drafts\pr-123-review.md"
```

The JSON output includes:

- `pull`
- `jira_issues`
- `analysis`
- `orchestration`
- `draft`
- `publish_target`

## 6. Capability Commands

GitHub context only:

```powershell
& .\.github\skills\github-pr-context\scripts\github_pr_context.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -Mode auto
```

Jira context only:

```powershell
& .\.github\skills\jira-issue-context\scripts\jira_issue_context.ps1 -InputPath "github-bundle.json" -Mode auto
```

Write review from an existing combined bundle:

```powershell
& .\.github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath "combined-bundle.json" -OutputFormat json -DraftPath "pr-review-drafts\pr-123-review.md"
```

Current Java expert module path:

```text
.github/skills/pr-review-writer/scripts/analyzers/java/java_expert_analyzer.ps1
```

Publish or update the managed PR comment:

```powershell
& .\.github\skills\pr-review-publisher\scripts\pr_review_publisher.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -DraftPath "pr-review-drafts\pr-123-review.md" -Mode real
```

## 7. Subagent Guidance

The orchestrator should prefer local execution unless at least one of these is true:

- mode is `real` or `auto`
- PR size is large by file count or churn
- multiple Jira keys are present
- the user explicitly asks for subagents, parallel review, or deeper review

Recommended split:

- `Agent A`: GitHub Context Worker
- `Agent B`: Jira Context Worker
- `Agent C`: Java Expert Review Worker
- main agent: integration, final draft, publish decision

## 8. Verification Commands

PowerShell smoke path:

```powershell
& .\.github\skills\pr-jira-review\scripts\tests\smoke_review_skill.ps1
```
