function ConvertFrom-JsonCompat([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -Depth 100
    }
    return $Json | ConvertFrom-Json
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cacheRoot = "test-output\confluence-knowledge-qa-smoke"
if (Test-Path $cacheRoot) {
    Remove-Item $cacheRoot -Recurse -Force
}

$scriptPath = ".github\skills\confluence-knowledge-qa\scripts\confluence_context.ps1"
$pageOne = "https://abc.com/confluence/pages/viewpage.action?pageId=1001"
$pageTwo = "https://abc.com/confluence/display/ENG/Incident+Guide?pageId=1002"

$first = ConvertFrom-JsonCompat ((& $scriptPath -PageUrls $pageOne -Mode mock -MergeMode append -ClearSession -CacheRoot $cacheRoot | Out-String))
if ($first.page_count -ne 1) { throw "Expected page_count 1 for initial load." }
if ($first.pages[0].title -ne "Platform Runbook") { throw "Unexpected first page title." }
if ($first.combined_sections.Count -lt 2) { throw "Expected combined sections for initial load." }

$second = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Add this page too: $pageTwo" -Mode mock -MergeMode append -CacheRoot $cacheRoot | Out-String))
if ($second.page_count -ne 2) { throw "Expected page_count 2 after append." }

$reused = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Answer from the current loaded pages" -Mode mock -CacheRoot $cacheRoot | Out-String))
if ($reused.page_count -ne 2) { throw "Expected page_count 2 for manifest reuse." }

$replaced = ConvertFrom-JsonCompat ((& $scriptPath -PageUrls $pageTwo -Mode mock -MergeMode replace -CacheRoot $cacheRoot | Out-String))
if ($replaced.page_count -ne 1) { throw "Expected page_count 1 after replace." }
if ($replaced.pages[0].id -ne "1002") { throw "Replace should keep only page 1002." }

$refreshed = ConvertFrom-JsonCompat ((& $scriptPath -Mode mock -Refresh -CacheRoot $cacheRoot | Out-String))
if ($refreshed.page_count -ne 1) { throw "Refresh should reload the active manifest set." }
if (-not (Test-Path $refreshed.session_manifest_path)) { throw "Manifest path should exist." }

[ordered]@{
    status = "ok"
    checks = @(
        "initial-load",
        "append",
        "manifest-reuse",
        "replace",
        "refresh"
    )
} | ConvertTo-Json -Depth 5
