# PR Jira Review Usage Guide

## 1. Purpose

`pr-jira-review` is a local Codex skill for reviewing a GitHub pull request against Jira context.

It supports three review modes:

- `auto`: try live APIs first, then fall back to mock data if live review cannot run
- `mock`: run a fixed demo flow with bundled sample data
- `real`: fetch live PR data from GitHub REST API and Jira issue data from Jira API v2

Use it when you want Codex chat to turn a PR URL into a structured Markdown review focused on:

- implementation risk
- Jira alignment
- missing tests
- reviewer questions

## 2. Prerequisites

Before using the skill, make sure:

- Python 3 is installed and available as `python` on `PATH`
- you know your repository root, shown below as `<repo-root>`
- your local Codex skills directory exists or can be created

Default local Codex skills directory:

- Windows: `%USERPROFILE%\.codex\skills`
- If `CODEX_HOME` is set, use `$CODEX_HOME\skills` instead

## 3. Skill Paths

Use these logical paths in the guide instead of machine-specific absolute paths:

- repository skill source: `<repo-root>\.github\skills\pr-jira-review`
- installed local skill path: `<codex-skills-dir>\pr-jira-review`

Example values on one machine might be:

- `<repo-root>` -> `D:\code\vscodeSkills`
- `<codex-skills-dir>` -> `C:\Users\<your-user>\.codex\skills`

Do not assume these exact example values on every machine.

## 4. Install the Skill for Chat

If the skill is not already visible in chat, link the repository skill into the local Codex skills directory.

PowerShell example:

```powershell
$repoRoot = "D:\path\to\your\repo"
$codexSkillsDir = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path $env:USERPROFILE ".codex\skills"
}

New-Item -ItemType Directory -Force -Path $codexSkillsDir | Out-Null

New-Item -ItemType SymbolicLink `
  -Path (Join-Path $codexSkillsDir "pr-jira-review") `
  -Target (Join-Path $repoRoot ".github\skills\pr-jira-review")
```

Notes:

- On Windows, creating symlinks may require Developer Mode or an elevated shell.
- If the target link already exists, remove or update it before recreating it.
- After installing or updating the skill, open a new Codex chat session.
- Use `$pr-jira-review` explicitly the first few times so the skill is selected reliably.

## 5. Demo the Mock Flow in Chat

Recommended demo prompt:

```text
Use $pr-jira-review in mock mode to review this PR:
https://github.com/acme/payments-service/pull/123

Focus on:
- risk
- Jira alignment
- missing tests

Return the standard Markdown review template.
```

Stricter version if the model does not follow the skill reliably:

```text
Use $pr-jira-review and run the local mock review flow for this PR:
https://github.com/acme/payments-service/pull/123
Do not call live APIs. Use mock data and return the standard PR review Markdown.
```

If you want chat to execute the script directly:

```text
Use $pr-jira-review.
Run:
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/acme/payments-service/pull/123" --mode mock
Then show me the Markdown output.
```

## 6. Run from the Terminal

From `<repo-root>`:

Mock mode:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/acme/payments-service/pull/123" --mode mock
```

Auto mode:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/acme/payments-service/pull/123" --mode auto
```

Structured JSON output:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/acme/payments-service/pull/123" --mode mock --output json
```

## 7. Configure Live Mode

Set the required Jira variables:

```powershell
$env:JIRA_BASE_URL="https://your-company.atlassian.net"
$env:JIRA_USER_EMAIL="dev@example.com"
$env:JIRA_API_TOKEN="jira_xxx"
```

Optional GitHub and Jira settings:

```powershell
$env:GITHUB_TOKEN="ghp_xxx"
$env:GITHUB_API_BASE_URL="https://api.github.com"
$env:JIRA_ACCEPTANCE_FIELD_IDS="customfield_10010,customfield_10142"
```

Notes:

- `GITHUB_TOKEN` is strongly recommended for public repositories and effectively required for private repositories.
- `GITHUB_API_BASE_URL` is useful for GitHub Enterprise or other non-`github.com` hosts.

Run live mode:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "https://github.com/org/repo/pull/123" --mode real
```

You can also let the script extract the PR URL from the original chat-style request:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/org/repo/pull/123" --mode real
```

## 8. How Live Mode Works

1. Extract the PR URL from `--pr-url` or `--prompt-text`.
2. Parse `<host>/<org>/<repo>/pull/<number>`.
3. Fetch pull request details, changed files, commits, issue comments, and review comments from GitHub REST API.
4. Extract Jira keys from the PR title, PR body, branch name, and commit messages.
5. Fetch matching Jira issues from Jira API v2.
6. Render a fixed Markdown review.

For non-`github.com` hosts, the script defaults to `https://<host>/api/v3` unless `GITHUB_API_BASE_URL` is set.

## 9. Output Format

The generated review uses this section order:

1. `# PR Review`
2. `## Review Scope`
3. `## PR Summary`
4. `## Jira Context`
5. `## Jira Alignment`
6. `## Risk Assessment`
7. `## Test Assessment`
8. `## Reviewer Questions`
9. `## Recommendation`
10. `## Positive Signals`

The content is heuristic. It is intended to accelerate review, not replace engineering judgment.

## 10. Mock Data

Default bundled mock payload:

- `.github/skills/pr-jira-review/assets/mock/default-review-bundle.json`

The mock bundle contains:

- a sample PR URL
- sample GitHub pull request metadata
- changed files
- commit messages
- issue comments and review comments
- a Jira issue payload keyed by Jira ID

You can point the script at another mock bundle with:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --mode mock --mock-data path\to\your-bundle.json
```

## 11. Common Issues

### Chat does not find the skill

Check that `<codex-skills-dir>\pr-jira-review` exists, then start a new chat session.

### The model does not honor mock mode

Use the stricter prompt shown above or instruct chat to run the script directly with `--mode mock`.

### Live mode fails immediately

Check:

- `JIRA_BASE_URL`
- `JIRA_USER_EMAIL`
- `JIRA_API_TOKEN`
- `GITHUB_TOKEN` when the repository is private
- network access to GitHub and Jira

### GitHub Enterprise host returns the wrong API base

Set `GITHUB_API_BASE_URL` explicitly.

### No Jira issue is loaded

Check whether the PR title, body, branch, or commit messages actually contain a Jira key like `PAY-248`.

## 12. Verification Commands

From `<repo-root>`:

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/acme/payments-service/pull/123" --mode mock
python -m unittest discover -s .github/skills/pr-jira-review/scripts/tests -v
```

Optional skill validation command:

```powershell
$codexSkillsDir = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path $env:USERPROFILE ".codex\skills"
}
$codexHome = Split-Path $codexSkillsDir -Parent
python (Join-Path $codexHome "skills\.system\skill-creator\scripts\quick_validate.py") .github/skills/pr-jira-review
```
