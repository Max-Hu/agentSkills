#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../../.." && pwd)"
cd "$repo_root"

github_json="$(bash .github/skills/github-pr-context/scripts/github_pr_context.sh --mode mock)"
node -e "const data = JSON.parse(process.argv[1]); if (!data.pull?.title) process.exit(1);" "$github_json"

jira_json="$(bash .github/skills/jira-issue-context/scripts/jira_issue_context.sh --input .github/skills/pr-jira-review/assets/mock/default-review-bundle.json --mode mock)"
node -e "const data = JSON.parse(process.argv[1]); if (!(data.jira_keys || []).length) process.exit(1);" "$jira_json"

writer_json="$(bash .github/skills/pr-review-writer/scripts/pr_review_writer.sh --input .github/skills/pr-jira-review/assets/mock/default-review-bundle.json --output json --draft-path test-output/bash-smoke-writer-review.md)"
node -e "const data = JSON.parse(process.argv[1]); if (!data.analysis?.recommendation) process.exit(1);" "$writer_json"

review_json="$(bash .github/skills/pr-jira-review/scripts/review_pr.sh --mode mock --output json --draft-path test-output/bash-smoke-main-review.md)"
node -e "const data = JSON.parse(process.argv[1]); if (!data.publish_target?.managed_marker) process.exit(1);" "$review_json"

publish_json="$(bash .github/skills/pr-review-publisher/scripts/pr_review_publisher.sh --pr-url https://github.com/acme/payments-service/pull/123 --input test-output/bash-smoke-main-review.md --mode mock)"
node -e "const data = JSON.parse(process.argv[1]); if (data.action !== 'created') process.exit(1);" "$publish_json"

echo 'Bash smoke review flow passed.'
