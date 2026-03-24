# Configuration

## Required environment variables for live review

- `JIRA_BASE_URL`
- `JIRA_USERNAME`
- `JIRA_PASSWORD`

## Optional environment variables

- `GITHUB_USERNAME`
- `GITHUB_TOKEN`
- `GITHUB_API_BASE_URL`

## Notes

- `pr-jira-review` and `pr-review-publisher` both reuse the same GitHub auth layer.
- Publishing targets the PR issue comment endpoint, not inline review comments.
- The managed comment marker is `<!-- pr-review-report:managed -->`.
- If you set either `GITHUB_USERNAME` or `GITHUB_TOKEN`, set both.
