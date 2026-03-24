param(
    [string]$InputPath,
    [ValidateSet("auto", "real", "mock")]
    [string]$Mode = "auto",
    [string]$MockData = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Get-DefaultMockDataPath {
    return Join-Path $PSScriptRoot "..\..\pr-jira-review\assets\mock\default-review-bundle.json"
}

function Get-JiraKeys([object]$Bundle) {
    $texts = [System.Collections.Generic.List[string]]::new()
    if ($Bundle.pull.title) { [void]$texts.Add([string]$Bundle.pull.title) }
    if ($Bundle.pull.body) { [void]$texts.Add([string]$Bundle.pull.body) }
    if ($Bundle.pull.head.ref) { [void]$texts.Add([string]$Bundle.pull.head.ref) }
    foreach ($commit in @($Bundle.commits)) {
        if ($commit.commit.message) {
            [void]$texts.Add([string]$commit.commit.message)
        }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($text in $texts) {
        foreach ($match in [regex]::Matches($text, '\b([A-Z][A-Z0-9]+-\d+)\b')) {
            $key = $match.Groups[1].Value
            if ($seen.Add($key)) {
                [void]$keys.Add($key)
            }
        }
    }
    return @($keys)
}

function Get-JiraHeaders {
    if (-not $env:JIRA_USERNAME -or -not $env:JIRA_PASSWORD) {
        throw "Live mode requires JIRA_USERNAME and JIRA_PASSWORD."
    }
    $pair = "{0}:{1}" -f $env:JIRA_USERNAME, $env:JIRA_PASSWORD
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{
        Accept = "application/json"
        Authorization = "Basic $token"
        "User-Agent" = "jira-issue-context-skill"
    }
}

function Invoke-JsonGet([string]$Url, [hashtable]$Headers) {
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
    } catch {
        throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message)
    }
}

function Load-MockBundle([string]$Path, [string[]]$Keys) {
    $raw = Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json -Depth 100
    $allIssues = $raw.jira_issues
    $selected = [ordered]@{}
    if ($Keys.Count -eq 0) {
        foreach ($prop in $allIssues.PSObject.Properties) {
            $selected[$prop.Name] = $prop.Value
        }
        $selectedKeys = @($selected.Keys)
    } else {
        foreach ($key in $Keys) {
            if ($allIssues.PSObject.Properties.Name -contains $key) {
                $selected[$key] = $allIssues.$key
            }
        }
        $selectedKeys = $Keys
    }
    return @{ jira_keys = $selectedKeys; jira_issues = $selected }
}

function Fetch-JiraIssues([string[]]$Keys) {
    if (-not $env:JIRA_BASE_URL) {
        throw "Live mode requires JIRA_BASE_URL."
    }
    $headers = Get-JiraHeaders
    $issues = [ordered]@{}
    foreach ($key in $Keys) {
        $safeKey = [Uri]::EscapeDataString($key)
        $base = $env:JIRA_BASE_URL.TrimEnd('/')
        $issue = Invoke-JsonGet "$base/rest/api/2/issue/$safeKey" $headers
        $comments = Invoke-JsonGet "$base/rest/api/2/issue/$safeKey/comment" $headers
        $issue | Add-Member -NotePropertyName comments -NotePropertyValue @($comments.comments) -Force
        $issues[$key] = $issue
    }
    return $issues
}

try {
    if (-not $InputPath) {
        throw "Provide -InputPath with a GitHub bundle JSON file."
    }
    $resolvedMock = if ($MockData) { $MockData } else { Get-DefaultMockDataPath }
    $bundle = Get-Content -Raw -Encoding UTF8 $InputPath | ConvertFrom-Json -Depth 100
    $keys = @(Get-JiraKeys $bundle)

    if ($Mode -eq "mock") {
        $modeUsed = "mock"
        $jiraBundle = Load-MockBundle $resolvedMock $keys
    } elseif ($keys.Count -eq 0) {
        $modeUsed = "no-jira"
        $jiraBundle = @{ jira_keys = @(); jira_issues = [ordered]@{} }
    } else {
        try {
            $modeUsed = "real"
            $jiraBundle = @{ jira_keys = $keys; jira_issues = Fetch-JiraIssues $keys }
        } catch {
            if ($Mode -ne "auto") {
                throw
            }
            $modeUsed = "mock-fallback"
            $jiraBundle = Load-MockBundle $resolvedMock $keys
        }
    }

    $payload = [ordered]@{ mode_used = $modeUsed }
    foreach ($entry in $jiraBundle.GetEnumerator()) {
        $payload[$entry.Key] = $entry.Value
    }
    $payload | ConvertTo-Json -Depth 100
} catch {
    Fail $_.Exception.Message
}


