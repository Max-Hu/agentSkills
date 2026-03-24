# PR Jira Review Usage Guide

## 1. Purpose

`pr-jira-review` is now the orchestrator skill for a multi-skill review workflow:

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

From `<repo-root>`:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "https://github.com/acme/payments-service/pull/123" --mode auto --output json --draft-path "pr-review-drafts\pr-123-review.md"
```

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
python .github/skills/github-pr-context/scripts/github_pr_context.py --pr-url "https://github.com/acme/payments-service/pull/123" --mode auto
```

Jira context only:

```powershell
python .github/skills/jira-issue-context/scripts/jira_issue_context.py --input "github-bundle.json" --mode auto
```

Write review from existing combined bundle:

```powershell
python .github/skills/pr-review-writer/scripts/pr_review_writer.py --input "combined-bundle.json" --output json --draft-path "pr-review-drafts\pr-123-review.md"
```

Publish or update the managed PR comment:

```powershell
python .github/skills/pr-review-publisher/scripts/pr_review_publisher.py --pr-url "https://github.com/acme/payments-service/pull/123" --input "pr-review-drafts\pr-123-review.md" --mode real
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

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "https://github.com/acme/payments-service/pull/123" --mode mock --output json --draft-path "pr-review-drafts\pr-123-review.md"
python -m unittest discover -s .github/skills/pr-jira-review/scripts/tests -v
```

