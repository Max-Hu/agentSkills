function ConvertFrom-JsonCompat([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -Depth 100
    }
    return $Json | ConvertFrom-Json
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cacheRoot = "test-output\ice-change-qa-smoke"
if (Test-Path $cacheRoot) {
    Remove-Item $cacheRoot -Recurse -Force
}

$scriptPath = ".github\skills\ice-change-qa\scripts\ice_change_context.ps1"

$first = ConvertFrom-JsonCompat ((& $scriptPath -Ids 9001 -Mode mock -MergeMode append -ClearSession -CacheRoot $cacheRoot | Out-String))
if ($first.change_count -ne 1) { throw "Expected change_count 1 for initial load." }
if ($first.changes[0].status -ne "complete") { throw "Expected complete status for initial load." }
if ($null -ne $first.changes[0].updates) { throw "Expected updates to stay null by default." }
if ($first.combined_update_text) { throw "Expected empty combined_update_text by default." }
if ($first.warnings.Count -ne 0) { throw "Expected no warnings for change-only load." }
if (-not $first.combined_qa_text) { throw "Expected combined QA text for initial load." }

$second = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Add change 9002 and inspect https://abc.com/ice/changes/9002" -Mode mock -MergeMode append -CacheRoot $cacheRoot | Out-String))
if ($second.change_count -ne 2) { throw "Expected change_count 2 after append." }
$change9002Default = @($second.changes | Where-Object { [string]$_.id -eq '9002' })[0]
if ($null -ne $change9002Default.updates) { throw "Expected no updates for 9002 without explicit request." }
if ($second.warnings.Count -ne 0) { throw "Expected no warnings for change-only append." }

$withUpdates = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Show the latest updates for change 9002" -Mode mock -CacheRoot $cacheRoot | Out-String))
$change9002WithUpdates = @($withUpdates.changes | Where-Object { [string]$_.id -eq '9002' })[0]
if ($null -eq $change9002WithUpdates.updates) { throw "Expected updates when explicitly requested." }
if ($change9002WithUpdates.resolved_updaters.PSObject.Properties['u-999'].Value -ne 'u-999') { throw "Expected unresolved updater fallback for u-999." }
if ($withUpdates.warnings.Count -lt 1) { throw "Expected a warning for unresolved updater fallback." }

$reused = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Answer from the current loaded changes" -Mode mock -CacheRoot $cacheRoot | Out-String))
if ($reused.change_count -ne 2) { throw "Expected change_count 2 for manifest reuse." }
$reused9002 = @($reused.changes | Where-Object { [string]$_.id -eq '9002' })[0]
if ($null -ne $reused9002.updates) { throw "Expected updates to stay hidden on plain reuse." }
if ($reused.warnings.Count -ne 0) { throw "Expected no warnings on plain reuse after an update request." }

$replaced = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Show updates for change 9003" -Mode mock -MergeMode replace -CacheRoot $cacheRoot | Out-String))
if ($replaced.change_count -ne 1) { throw "Expected change_count 1 after replace." }
if ($replaced.changes[0].status -ne 'partial') { throw "Expected partial status when updates fail." }
if ($replaced.errors.Count -lt 1) { throw "Expected an error entry for updates failure." }

$refreshed = ConvertFrom-JsonCompat ((& $scriptPath -PromptText "Refresh and show updates for the current loaded changes" -Mode mock -Refresh -CacheRoot $cacheRoot | Out-String))
if ($refreshed.change_count -ne 1) { throw "Refresh should reload the active manifest set." }
if (-not (Test-Path $refreshed.session_manifest_path)) { throw "Manifest path should exist." }

$cleared = ConvertFrom-JsonCompat ((& $scriptPath -Mode mock -ClearSession -CacheRoot $cacheRoot | Out-String))
if ($cleared.change_count -ne 0) { throw "Expected change_count 0 after clear." }

[ordered]@{
    status = "ok"
    checks = @(
        "initial-load-change-only",
        "append-change-only",
        "explicit-update-enrichment",
        "manifest-reuse-without-updates",
        "replace-with-update-failure",
        "refresh",
        "clear-session"
    )
} | ConvertTo-Json -Depth 5
