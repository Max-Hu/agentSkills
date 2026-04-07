Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Text([string]$Path) {
    return [System.IO.File]::ReadAllText((Resolve-Path $Path), [System.Text.Encoding]::UTF8)
}

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw $Message }
}

function Invoke-ScriptExpectFailure([string]$ScriptPath, [string[]]$Arguments, [string]$ExpectedPattern) {
    $hostPath = (Get-Process -Id $PID).Path
    $output = & $hostPath -NoProfile -File $ScriptPath @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { throw "Smoke test failed: expected $ScriptPath to fail." }
    if ($output -notmatch $ExpectedPattern) { throw "Smoke test failed: expected failure output '$ExpectedPattern' from $ScriptPath." }
    return $output
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')
Set-Location $root

$reviewWriterAnalyzer = '.github\skills\pr-review-writer\scripts\analyzers\java\java_expert_analyzer.ps1'
$mainAnalyzer = '.github\skills\pr-jira-review\scripts\analyzers\java\java_expert_analyzer.ps1'
$reviewScript = '.github\skills\pr-jira-review\scripts\review_pr.ps1'
$githubScript = '.github\skills\github-pr-context\scripts\github_pr_context.ps1'
$jiraScript = '.github\skills\jira-issue-context\scripts\jira_issue_context.ps1'
$publisherScript = '.github\skills\pr-review-publisher\scripts\pr_review_publisher.ps1'

if (-not (Test-Path $reviewWriterAnalyzer)) { throw 'Smoke test failed: missing shared Java expert analyzer.' }
if (-not (Test-Path $mainAnalyzer)) { throw 'Smoke test failed: missing pr-jira-review Java analyzer path.' }

$reviewText = Get-Text $reviewScript
$githubText = Get-Text $githubScript
$jiraText = Get-Text $jiraScript
$publisherText = Get-Text $publisherScript
$skillText = Get-Text '.github\skills\pr-jira-review\SKILL.md'
$usageText = Get-Text '.github\skills\pr-jira-review\references\usage-guide.md'

Assert-Contains $reviewText 'ValidateSet\("auto", "real"\)' 'Smoke test failed: review_pr.ps1 still accepts mock mode.'
Assert-Contains $githubText 'ValidateSet\("auto", "real"\)' 'Smoke test failed: github_pr_context.ps1 still accepts mock mode.'
Assert-Contains $jiraText 'ValidateSet\("auto", "real"\)' 'Smoke test failed: jira_issue_context.ps1 still accepts mock mode.'
Assert-Contains $publisherText 'ValidateSet\("real"\)' 'Smoke test failed: pr_review_publisher.ps1 should only accept real mode.'

Assert-NotContains $reviewText '\bMockData\b' 'Smoke test failed: review_pr.ps1 still exposes MockData.'
Assert-NotContains $githubText '\bMockData\b' 'Smoke test failed: github_pr_context.ps1 still exposes MockData.'
Assert-NotContains $jiraText '\bMockData\b' 'Smoke test failed: jira_issue_context.ps1 still exposes MockData.'

Assert-NotContains $reviewText 'Get-DefaultMockDataPath|Load-MockBundle|mock-fallback' 'Smoke test failed: review_pr.ps1 still contains mock helpers or fallback.'
Assert-NotContains $githubText 'Get-DefaultMockDataPath|Load-MockBundle|mock-fallback' 'Smoke test failed: github_pr_context.ps1 still contains mock helpers or fallback.'
Assert-NotContains $jiraText 'Get-DefaultMockDataPath|Load-MockBundle|mock-fallback' 'Smoke test failed: jira_issue_context.ps1 still contains mock helpers or fallback.'
Assert-NotContains $publisherText '#issuecomment-mock|\bmock\b' 'Smoke test failed: pr_review_publisher.ps1 still contains mock publishing logic.'

if (Test-Path '.github\skills\pr-jira-review\assets\mock\default-review-bundle.json') {
    throw 'Smoke test failed: mock review bundle still exists.'
}

Assert-NotContains $skillText '\bmock\b' 'Smoke test failed: pr-jira-review SKILL.md still mentions mock mode.'
Assert-NotContains $usageText '\bmock\b' 'Smoke test failed: pr-jira-review usage guide still mentions mock mode.'

Invoke-ScriptExpectFailure $reviewScript @() 'No PR URL found'
Invoke-ScriptExpectFailure $githubScript @() 'No PR URL found'
Invoke-ScriptExpectFailure $publisherScript @() 'Provide --PrUrl'

$tempBundle = Join-Path $env:TEMP ('pr-jira-live-smoke-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    [System.IO.File]::WriteAllText($tempBundle, '{"pull":{"title":"PAY-1 Demo","body":"","head":{"ref":"feature/PAY-1"}}, "commits":[{"commit":{"message":"PAY-1 demo"}}]}', [System.Text.Encoding]::UTF8)
    $jiraFailure = Invoke-ScriptExpectFailure $jiraScript @('-InputPath', $tempBundle) 'Live mode requires JIRA_BASE_URL|Live mode requires JIRA_USERNAME and JIRA_PASSWORD'
} finally {
    if (Test-Path $tempBundle) { Remove-Item $tempBundle -Force }
}

$requiredEnv = @('GITHUB_TOKEN', 'JIRA_BASE_URL', 'JIRA_USERNAME', 'JIRA_PASSWORD', 'PR_JIRA_REVIEW_SMOKE_PR_URL')
$missingEnv = @($requiredEnv | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
if ($missingEnv.Count -gt 0) {
    throw ('Live smoke test requires: ' + ($missingEnv -join ', '))
}

$artifactRoot = Join-Path $env:TEMP ('pr-jira-review-live-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
try {
    $draftPath = Join-Path $artifactRoot 'review.md'
    $reviewOutput = & $reviewScript -PrUrl $env:PR_JIRA_REVIEW_SMOKE_PR_URL -Mode auto -OutputFormat json -DraftPath $draftPath | Out-String
    if (-not $reviewOutput) { throw 'Smoke test failed: live review returned no output.' }
    if (-not (Test-Path $draftPath)) { throw 'Smoke test failed: live review did not write the draft file.' }
    if ($reviewOutput -match 'mock|mock-fallback') { throw 'Smoke test failed: live review output still references mock mode.' }
} finally {
    if (Test-Path $artifactRoot) { Remove-Item $artifactRoot -Recurse -Force }
}

'PowerShell smoke review flow passed.'
