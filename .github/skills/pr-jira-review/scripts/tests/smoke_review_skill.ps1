function ConvertFrom-JsonCompat([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -Depth 100
    }
    return $Json | ConvertFrom-Json
}

if (-not (Test-Path .github\skills\pr-review-writer\scripts\analyzers\java\java_expert_analyzer.ps1)) { throw 'Writer smoke test failed: missing Java expert analyzer module.' }
if (-not (Test-Path .github\skills\pr-jira-review\scripts\analyzers\java\java_expert_analyzer.ps1)) { throw 'Main review smoke test failed: missing Java analyzer highlight path.' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')
Set-Location $root
$artifactRoot = Join-Path $env:TEMP ('pr-review-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

function Get-FindingByTitle([object[]]$Findings, [string]$Title) {
    foreach ($finding in @($Findings)) {
        if ($finding.title -eq $Title) { return $finding }
    }
    throw "Smoke test failed: missing finding '$Title'."
}

function Get-MarkdownSection([string]$Markdown, [string]$Heading) {
    $start = $Markdown.IndexOf($Heading)
    if ($start -lt 0) { throw "Smoke test failed: missing markdown heading '$Heading'." }
    $next = $Markdown.IndexOf("`n### ", $start + $Heading.Length)
    if ($next -lt 0) { return $Markdown.Substring($start) }
    return $Markdown.Substring($start, $next - $start)
}

$github = ConvertFrom-JsonCompat (& .\.github\skills\github-pr-context\scripts\github_pr_context.ps1 -Mode mock | Out-String)
if (-not $github.pull.title) { throw 'GitHub context smoke test failed: missing pull title.' }
if (-not ($github.pull.title -match 'Java|Spring')) { throw 'GitHub context smoke test failed: expected Java-oriented mock title.' }

$jira = ConvertFrom-JsonCompat (& .\.github\skills\jira-issue-context\scripts\jira_issue_context.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -Mode mock | Out-String)
if (-not @($jira.jira_keys).Count) { throw 'Jira context smoke test failed: missing jira_keys.' }
if (-not (@($jira.jira_keys) -contains 'PAY-517')) { throw 'Jira context smoke test failed: expected PAY-517.' }

$writerDraft = Join-Path $artifactRoot 'smoke-writer-review.md'
$mainDraft = Join-Path $artifactRoot 'smoke-main-review.md'
$writer = ConvertFrom-JsonCompat (& .\.github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -OutputFormat json -DraftPath $writerDraft | Out-String)
if (-not $writer.analysis.recommendation) { throw 'Writer smoke test failed: missing recommendation.' }
if ($writer.analysis.code_review_mode -ne 'java-expert-diff') { throw 'Writer smoke test failed: unexpected code review mode.' }
if ($writer.analysis.code_review_reviewer -ne 'Senior Java/Spring Reviewer') { throw 'Writer smoke test failed: unexpected reviewer persona.' }
if (@($writer.analysis.code_review_supported_targets).Count -lt 5) { throw 'Writer smoke test failed: missing supported review targets.' }
if (@($writer.analysis.detailed_findings | Where-Object { $_.category -eq 'Code Quality' }).Count -eq 0) { throw 'Writer smoke test failed: expected Java expert code findings.' }
if (-not (Test-Path $writerDraft)) { throw 'Writer smoke test failed: missing draft file.' }
$broadCatch = Get-FindingByTitle $writer.analysis.detailed_findings 'Broad catch obscures Java failure semantics'
if ($broadCatch.primary_file -ne 'src/main/java/com/acme/payments/refund/RefundService.java') { throw 'Writer smoke test failed: broad catch finding missing primary_file.' }
if (-not $broadCatch.code_detail.snippet) { throw 'Writer smoke test failed: broad catch finding missing code_detail.snippet.' }
if (-not $broadCatch.reference_fix) { throw 'Writer smoke test failed: broad catch finding missing reference_fix.' }
$idempotency = Get-FindingByTitle $writer.analysis.detailed_findings 'Idempotency marker is written before the side effect completes'
if (-not ($idempotency.reference_fix -match 'ledgerClient\.applyRefund')) { throw 'Writer smoke test failed: idempotency finding missing reference fix details.' }
$optionalGet = Get-FindingByTitle $writer.analysis.detailed_findings 'Optional.get() assumes data presence in the changed path'
if (-not ($optionalGet.code_detail.snippet -match 'findById')) { throw 'Writer smoke test failed: Optional.get finding missing controller snippet.' }
$secretFinding = Get-FindingByTitle $writer.analysis.detailed_findings 'Spring config introduces a literal secret value'
if (-not ($secretFinding.reference_fix -match 'PAYMENTS_REFUND_WEBHOOK_SECRET')) { throw 'Writer smoke test failed: secret finding missing externalized secret reference.' }
$skipTests = Get-FindingByTitle $writer.analysis.detailed_findings 'Build configuration disables or skips the Java test phase'
if (-not ($skipTests.reference_fix -match 'maven\.test\.skip>false<')) { throw 'Writer smoke test failed: build config finding missing reference fix.' }
$summaryFinding = Get-FindingByTitle $writer.analysis.findings_summary 'Broad catch obscures Java failure semantics'
if (-not $summaryFinding.has_code_detail) { throw 'Writer smoke test failed: findings summary missing has_code_detail.' }

$writerMarkdown = & .\.github\skills\pr-review-writer\scripts\pr_review_writer.ps1 -InputPath .github\skills\pr-jira-review\assets\mock\default-review-bundle.json -OutputFormat markdown | Out-String
if (-not ($writerMarkdown -match '```diff')) { throw 'Writer smoke test failed: markdown missing diff code fence.' }
if (-not ($writerMarkdown -match '```java')) { throw 'Writer smoke test failed: markdown missing java reference fence.' }
$riskSection = Get-MarkdownSection $writerMarkdown '### 🟠 High-risk production paths were modified'
if ($riskSection -match 'Triggered diff:' -or $riskSection -match 'Reference fix') { throw 'Writer smoke test failed: non-code finding should not render code detail blocks.' }

$review = ConvertFrom-JsonCompat (& .\.github\skills\pr-jira-review\scripts\review_pr.ps1 -Mode mock -OutputFormat json -DraftPath $mainDraft | Out-String)
if (-not $review.publish_target.managed_marker) { throw 'Main review smoke test failed: missing publish_target.' }
if (-not $review.pull) { throw 'Main review smoke test failed: missing pull section.' }
if (-not $review.jira_issues) { throw 'Main review smoke test failed: missing jira_issues section.' }
if (-not $review.analysis) { throw 'Main review smoke test failed: missing analysis section.' }
if (-not $review.orchestration) { throw 'Main review smoke test failed: missing orchestration section.' }
if ($review.analysis.code_review_mode -ne 'java-expert-diff') { throw 'Main review smoke test failed: unexpected code review mode.' }
if ($review.analysis.code_review_reviewer -ne 'Senior Java/Spring Reviewer') { throw 'Main review smoke test failed: unexpected reviewer persona.' }
if (@($review.analysis.detailed_findings | Where-Object { $_.category -eq 'Code Quality' }).Count -eq 0) { throw 'Main review smoke test failed: expected Java expert code findings.' }
if (-not (Test-Path $mainDraft)) { throw 'Main review smoke test failed: missing draft file.' }
$mainBroadCatch = Get-FindingByTitle $review.analysis.detailed_findings 'Broad catch obscures Java failure semantics'
if (-not $mainBroadCatch.code_detail.snippet) { throw 'Main review smoke test failed: main review missing code_detail.snippet.' }
if (-not $mainBroadCatch.reference_fix) { throw 'Main review smoke test failed: main review missing reference_fix.' }

$publish = ConvertFrom-JsonCompat (& .\.github\skills\pr-review-publisher\scripts\pr_review_publisher.ps1 -PrUrl https://github.com/acme/payments-service/pull/123 -DraftPath $mainDraft -Mode mock | Out-String)
if ($publish.action -ne 'created') { throw 'Publisher smoke test failed: expected created action.' }

if (Test-Path $artifactRoot) { Remove-Item $artifactRoot -Recurse -Force }
'PowerShell smoke review flow passed.'
