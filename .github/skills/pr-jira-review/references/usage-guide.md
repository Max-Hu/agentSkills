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

## 2. Default Usage

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

## 3. Orchestrator Command

Windows / PowerShell:

```powershell
.github/skills/pr-jira-review/scripts/review_pr.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -Mode auto -OutputFormat json -DraftPath "pr-review-drafts\pr-123-review.md"
```

macOS / Linux / Bash:

```bash
.github/skills/pr-jira-review/scripts/review_pr.sh --pr-url "https://github.com/acme/payments-service/pull/123" --mode auto --output json --draft-path "pr-review-drafts/pr-123-review.md"
```

Bash mode expects `node` and `curl` to be available.

The JSON output includes:

- `pull`
- `jira_issues`
- `analysis`
- `orchestration`
- `draft`
- `publish_target`

## 4. Capability Commands

GitHub context only:

```powershell
.github/skills/github-pr-context/scripts/github_pr_context.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -Mode auto
```

```bash
.github/skills/github-pr-context/scripts/github_pr_context.sh --pr-url "https://github.com/acme/payments-service/pull/123" --mode auto
```

Jira context only:

```powershell
.github/skills/jira-issue-context/scripts/jira_issue_context.ps1 -InputPath "github-bundle.json" -Mode auto
```

```bash
.github/skills/jira-issue-context/scripts/jira_issue_context.sh --input "github-bundle.json" --mode auto
```

Write review from an existing combined bundle:

```powershell
.github/skills/pr-review-writer/scripts/pr_review_writer.ps1 -InputPath "combined-bundle.json" -OutputFormat json -DraftPath "pr-review-drafts\pr-123-review.md"
```

```bash
.github/skills/pr-review-writer/scripts/pr_review_writer.sh --input "combined-bundle.json" --output json --draft-path "pr-review-drafts/pr-123-review.md"
```

Publish or update the managed PR comment:

```powershell
.github/skills/pr-review-publisher/scripts/pr_review_publisher.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -DraftPath "pr-review-drafts\pr-123-review.md" -Mode real
```

```bash
.github/skills/pr-review-publisher/scripts/pr_review_publisher.sh --pr-url "https://github.com/acme/payments-service/pull/123" --input "pr-review-drafts/pr-123-review.md" --mode real
```

## 5. Subagent Guidance

The orchestrator should prefer local execution unless at least one of these is true:

- mode is `real` or `auto`
- PR size is large by file count or churn
- multiple Jira keys are present
- the user explicitly asks for subagents, parallel review, or deeper review

Recommended split:

- `Agent A`: GitHub Context Worker
- `Agent B`: Jira Context Worker
- `Agent C`: Review Analysis Worker
- main agent: integration, final draft, publish decision

## 6. Draft and Publish Model

The review draft is the editable source of truth.

- Generate the draft first.
- Edit the Markdown if needed.
- Publish from the draft file.
- Future publishes update the same managed PR issue comment instead of creating a new one.

Managed marker:

```html
<!-- pr-review-report:managed -->
```

## 7. Verification Commands

PowerShell smoke path:

```powershell
.github/skills/pr-jira-review/scripts/review_pr.ps1 -Mode mock -OutputFormat json -DraftPath "test-output\pr-123-review.md"
.github/skills/pr-review-publisher/scripts/pr_review_publisher.ps1 -PrUrl "https://github.com/acme/payments-service/pull/123" -DraftPath "test-output\pr-123-review.md" -Mode mock
```

Bash smoke path:

```bash
.github/skills/pr-jira-review/scripts/review_pr.sh --mode mock --output json --draft-path "test-output/pr-123-review.md"
.github/skills/pr-review-publisher/scripts/pr_review_publisher.sh --pr-url "https://github.com/acme/payments-service/pull/123" --input "test-output/pr-123-review.md" --mode mock
```
