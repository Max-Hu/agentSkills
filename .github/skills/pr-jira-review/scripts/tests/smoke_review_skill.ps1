if (-not (Test-Path .github\skills\pr-review-writer\scripts\analyzers\java\java_expert_analyzer.ps1)) { throw 'Writer smoke test failed: missing Java expert analyzer module.' }
if (-not (Test-Path .github\skills\pr-jira-review\scripts\analyzers\java\java_expert_analyzer.ps1)) { throw 'Main review smoke test failed: missing Java analyzer highlight path.' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')
Set-Location $root

$github = pwsh -File .github\skills\github-pr-context\scripts\github_pr_context.ps1 -Mode mock | ConvertFrom-Json -Depth 100
if (-not $github.pull.title) { throw 'GitHub context smoke test failed: missing pull title.' }
if (-not ($github.pull.title -match 'Java|Spring')) { throw 'GitHub context smoke test failed: expected Java-oriented mock title.' }

$jira = pwsh -File .github\skills\jira-issue-context\scripts\jira_issue_context.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -Mode mock | ConvertFrom-Json -Depth 100
if (-not @($jira.jira_keys).Count) { throw 'Jira context smoke test failed: missing jira_keys.' }
if (-not (@($jira.jira_keys) -contains 'PAY-517')) { throw 'Jira context smoke test failed: expected PAY-517.' }

$writer = pwsh -File .github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -OutputFormat json -DraftPath test-output\smoke-writer-review.md | ConvertFrom-Json -Depth 100
if (-not $writer.analysis.recommendation) { throw 'Writer smoke test failed: missing recommendation.' }
if ($writer.analysis.code_review_mode -ne 'java-expert-diff') { throw 'Writer smoke test failed: unexpected code review mode.' }
if ($writer.analysis.code_review_reviewer -ne 'Senior Java/Spring Reviewer') { throw 'Writer smoke test failed: unexpected reviewer persona.' }
if (@($writer.analysis.code_review_supported_targets).Count -lt 5) { throw 'Writer smoke test failed: missing supported review targets.' }
if (@($writer.analysis.detailed_findings | Where-Object { $_.category -eq 'Code Quality' }).Count -eq 0) { throw 'Writer smoke test failed: expected Java expert code findings.' }
if (-not (Test-Path test-output\smoke-writer-review.md)) { throw 'Writer smoke test failed: missing draft file.' }

$review = pwsh -File .github\skills\pr-jira-review\scripts\review_pr.ps1 -Mode mock -OutputFormat json -DraftPath test-output\smoke-main-review.md | ConvertFrom-Json -Depth 100
if (-not $review.publish_target.managed_marker) { throw 'Main review smoke test failed: missing publish_target.' }
if (-not $review.pull) { throw 'Main review smoke test failed: missing pull section.' }
if (-not $review.jira_issues) { throw 'Main review smoke test failed: missing jira_issues section.' }
if (-not $review.analysis) { throw 'Main review smoke test failed: missing analysis section.' }
if (-not $review.orchestration) { throw 'Main review smoke test failed: missing orchestration section.' }
if ($review.analysis.code_review_mode -ne 'java-expert-diff') { throw 'Main review smoke test failed: unexpected code review mode.' }
if ($review.analysis.code_review_reviewer -ne 'Senior Java/Spring Reviewer') { throw 'Main review smoke test failed: unexpected reviewer persona.' }
if (@($review.analysis.detailed_findings | Where-Object { $_.category -eq 'Code Quality' }).Count -eq 0) { throw 'Main review smoke test failed: expected Java expert code findings.' }
if (-not (Test-Path test-output\smoke-main-review.md)) { throw 'Main review smoke test failed: missing draft file.' }

$publish = pwsh -File .github\skills\pr-review-publisher\scripts\pr_review_publisher.ps1 -PrUrl https://github.com/acme/payments-service/pull/123 -DraftPath test-output\smoke-main-review.md -Mode mock | ConvertFrom-Json -Depth 100
if ($publish.action -ne 'created') { throw 'Publisher smoke test failed: expected created action.' }

'PowerShell smoke review flow passed.'

