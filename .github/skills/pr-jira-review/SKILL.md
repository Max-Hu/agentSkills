---
name: pr-jira-review
description: Review GitHub pull requests against Jira context with a local Python workflow. Use when the user provides a GitHub PR URL, asks for risk analysis, Jira alignment, missing-test review, or wants a fixed Markdown PR review that can run with real APIs or mock data.
---

# PR Jira Review

Review a GitHub pull request against Jira requirements and return a fixed Markdown review. Prefer real API mode when credentials are configured. Use mock mode for demos, offline iteration, or when credentials are unavailable.

## Workflow

1. Extract the PR URL from the user request. If the request does not contain a PR URL, ask for one.
2. Run the local review script:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "<user request>" --mode auto
```

3. Use `--mode real` when the user explicitly wants a live review. Use `--mode mock` when the user wants a demo or when live credentials are missing.
4. Return the generated Markdown review. Preserve the section structure unless the user asks for a different format.

## Live Mode

- Use the PR URL host to resolve the GitHub API base URL. Honor `GITHUB_API_BASE_URL` when it is set.
- Read Jira host and credentials from environment variables described in [references/configuration.md](./references/configuration.md).
- If no Jira key is found in the PR title, branch, body, or commits, call that out explicitly in the review.
- If the script reports missing configuration, tell the user exactly which variables are required.

## Mock Mode

- Use the bundled mock payload at [assets/mock/default-review-bundle.json](./assets/mock/default-review-bundle.json) unless the user provides another file.
- Use mock mode for demos, prompt iteration, and template reviews when external API access is not available.

## Output Expectations

- Keep the review grounded in fetched data, not generic advice.
- Focus on Jira alignment, implementation risk, and missing test coverage.
- Use the standard section order documented in [references/review-template.md](./references/review-template.md).
- Treat missing Jira linkage, large risky diffs, and code changes without tests as the highest-signal issues.
