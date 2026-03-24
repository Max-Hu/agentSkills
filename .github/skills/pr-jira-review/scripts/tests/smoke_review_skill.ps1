Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')
Set-Location $root

$github = pwsh -File .github\skills\github-pr-context\scripts\github_pr_context.ps1 -Mode mock | ConvertFrom-Json -Depth 100
if (-not $github.pull.title) { throw 'GitHub context smoke test failed: missing pull title.' }

$jira = pwsh -File .github\skills\jira-issue-context\scripts\jira_issue_context.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -Mode mock | ConvertFrom-Json -Depth 100
if (-not @($jira.jira_keys).Count) { throw 'Jira context smoke test failed: missing jira_keys.' }

$writer = pwsh -File .github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -OutputFormat json -DraftPath test-output\smoke-writer-review.md | ConvertFrom-Json -Depth 100
if (-not $writer.analysis.recommendation) { throw 'Writer smoke test failed: missing recommendation.' }

$review = pwsh -File .github\skills\pr-jira-review\scripts\review_pr.ps1 -Mode mock -OutputFormat json -DraftPath test-output\smoke-main-review.md | ConvertFrom-Json -Depth 100
if (-not $review.publish_target.managed_marker) { throw 'Main review smoke test failed: missing publish_target.' }

$publish = pwsh -File .github\skills\pr-review-publisher\scripts\pr_review_publisher.ps1 -PrUrl https://github.com/acme/payments-service/pull/123 -DraftPath test-output\smoke-main-review.md -Mode mock | ConvertFrom-Json -Depth 100
if ($publish.action -ne 'created') { throw 'Publisher smoke test failed: expected created action.' }

'PowerShell smoke review flow passed.'
