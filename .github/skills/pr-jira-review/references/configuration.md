# Configuration

## Required environment variables for live mode

- `JIRA_BASE_URL`: Base URL such as `https://your-company.atlassian.net`
- `JIRA_USER_EMAIL`: Jira Cloud login email for API v2 basic auth
- `JIRA_API_TOKEN`: Jira API token paired with `JIRA_USER_EMAIL`

## Optional environment variables

- `GITHUB_TOKEN`: Personal access token for GitHub REST API. Strongly recommended for public repositories and effectively required for private repositories.
- `GITHUB_API_BASE_URL`: Override for the GitHub API base URL. By default the script uses `https://api.github.com` for `github.com` and `https://<host>/api/v3` for other hosts.
- `JIRA_ACCEPTANCE_FIELD_IDS`: Comma-separated Jira field ids or names to inspect before falling back to description parsing. Example: `customfield_10010,customfield_10142`

## Example commands

```powershell
$env:GITHUB_TOKEN="ghp_xxx"
$env:JIRA_BASE_URL="https://example.atlassian.net"
$env:JIRA_USER_EMAIL="dev@example.com"
$env:JIRA_API_TOKEN="jira_xxx"
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "https://github.com/org/repo/pull/123" --mode real
```

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/org/repo/pull/123" --mode mock
```
