---
name: pr-jira-review
description: Orchestrate GitHub PR review against Jira context using reusable local skills for GitHub context, Jira context, review writing, editable Markdown drafts, and managed PR comment publishing. Use when the user gives a GitHub PR URL, asks for Jira alignment, implementation risk, missing tests, evidence-backed PR audit, wants the review saved as an editable draft, or wants subagent-friendly parallel review coordination before optionally publishing the review back to the PR.
---

# PR Jira Review

Use this as the single entrypoint skill. Keep the user experience simple: one prompt in, one review draft out.

## Core flow

1. Extract the PR URL from the request.
2. Choose mode:
   - `mock` for demo or offline requests.
   - `real` when the user explicitly asks for live data.
   - `auto` by default.
3. Decide whether subagents should be used.
4. Gather GitHub context.
5. Gather Jira context.
6. Generate the review report and Markdown draft.
7. If the user asks to publish, publish or update the managed PR comment.

Run the orchestrator first:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "<pr-url>" --mode auto --output json --draft-path "pr-review-drafts\pr-<number>-review.md"
```

Read these fields from the JSON result:

- `pull`
- `jira_issues`
- `analysis`
- `orchestration`
- `draft`
- `publish_target`

## Subagent policy

Use subagents only when they materially help:

- live or live-capable review (`real` / `auto`)
- large PRs by file count or churn
- multiple Jira keys
- the user explicitly asks for subagents, parallel review, or deeper review

When subagents are warranted, split work like this:

- `Agent A`: GitHub Context Worker
- `Agent B`: Jira Context Worker
- `Agent C`: Review Analysis Worker
- Main agent: integrate evidence, finalize Markdown, decide whether to publish

Do not duplicate work between agents. A and B run in parallel. C starts only after A and B finish.

## Capability skills

Use these sibling skills when you need a narrower step:

- `github-pr-context`
- `jira-issue-context`
- `pr-review-writer`
- `pr-review-publisher`

Prefer the main skill unless the user explicitly wants one stage only.

## Review standard

Keep the review evidence-backed and ordered by business risk:

1. Jira alignment
2. implementation and correctness risk
3. missing or weak tests
4. unresolved reviewer questions

Use the section order from [references/review-template.md](./references/review-template.md). Start with a severity-ranked findings summary, then detailed analysis with suggested fixes, then the structured evidence sources section.

## Draft and publish flow

Default output is an editable Markdown draft on disk.

1. Generate the draft with `pr-jira-review` or `pr-review-writer`.
2. Edit the draft if needed.
3. Publish with `pr-review-publisher`.
4. On later publishes, update the same managed PR comment instead of creating a new one.

Publish command:

```powershell
python .github/skills/pr-review-publisher/scripts/pr_review_publisher.py --pr-url "<pr-url>" --input "pr-review-drafts\pr-<number>-review.md" --mode real
```

