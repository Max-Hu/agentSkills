# Configuration

## Required environment variables for live mode

- `JIRA_BASE_URL`: Base URL such as `https://your-company.atlassian.net`
- `JIRA_USERNAME`: Jira username used for Basic Auth
- `JIRA_PASSWORD`: Jira password used for Basic Auth

## Optional environment variables

- `GITHUB_USERNAME`: GitHub username used for Basic Auth. Required together with `GITHUB_TOKEN` when GitHub authentication is needed.
- `GITHUB_TOKEN`: GitHub token used as the Basic Auth secret. Required together with `GITHUB_USERNAME` when GitHub authentication is needed.
- `GITHUB_API_BASE_URL`: Override for the GitHub API base URL. By default the script uses `https://api.github.com` for `github.com` and `https://<host>/api/v3` for other hosts.
- `JIRA_ACCEPTANCE_FIELD_IDS`: Comma-separated Jira field ids or names to inspect before falling back to description parsing. Example: `customfield_10010,customfield_10142`

## Notes

- Jira live mode now only supports `JIRA_USERNAME` + `JIRA_PASSWORD`.
- GitHub auth now only supports `GITHUB_USERNAME` + `GITHUB_TOKEN` via Basic Auth.
- If the repository is public, GitHub requests can still run without auth, but lower rate limits apply.
- If you set either `GITHUB_USERNAME` or `GITHUB_TOKEN`, you must set both.

## Example commands

```powershell
$env:GITHUB_USERNAME="octocat"
$env:GITHUB_TOKEN="ghp_xxx"
$env:JIRA_BASE_URL="https://example.atlassian.net"
$env:JIRA_USERNAME="jira-user"
$env:JIRA_PASSWORD="jira-password"
python .github/skills/pr-jira-review/scripts/review_pr.py --pr-url "https://github.com/org/repo/pull/123" --mode real
```

```powershell
python .github/skills/pr-jira-review/scripts/review_pr.py --prompt-text "Review this PR: https://github.com/org/repo/pull/123" --mode mock
```
