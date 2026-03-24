param(
    [string]$PrUrl,
    [string]$PromptText,
    [ValidateSet("auto", "real", "mock")]
    [string]$Mode = "auto",
    [string]$MockData = "",
    [string]$DraftPath,
    [ValidateSet("markdown", "json")]
    [string]$OutputFormat = "markdown"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ManagedMarker = "<!-- pr-review-report:managed -->"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Get-DefaultMockDataPath {
    return Join-Path $PSScriptRoot "..\assets\mock\default-review-bundle.json"
}

function Get-PrUrlFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, 'https?://[^\s]+/[^/\s]+/[^/\s]+/pull/\d+')
    if ($match.Success) { return $match.Value }
    return $null
}

function Parse-PrUrl([string]$Url) {
    try { $uri = [Uri]$Url } catch { throw "Unsupported PR URL: $Url" }
    $parts = $uri.AbsolutePath.Trim('/').Split('/')
    if ($parts.Length -ne 4 -or $parts[2] -ne 'pull') { throw "Unsupported PR URL: $Url" }
    return @{ Host = $uri.Host; Owner = $parts[0]; Repo = $parts[1]; Number = [int]$parts[3]; Url = $Url }
}

function Get-GitHubApiBase([string]$HostName) {
    if ($env:GITHUB_API_BASE_URL) { return $env:GITHUB_API_BASE_URL.TrimEnd('/') }
    if ($HostName.ToLowerInvariant() -eq 'github.com') { return 'https://api.github.com' }
    return "https://$HostName/api/v3"
}

function Get-GitHubHeaders {
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'pr-jira-review-skill'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)" }
    return $headers
}

function Get-JiraHeaders {
    if (-not $env:JIRA_USERNAME -or -not $env:JIRA_PASSWORD) { throw 'Live mode requires JIRA_USERNAME and JIRA_PASSWORD.' }
    $pair = "{0}:{1}" -f $env:JIRA_USERNAME, $env:JIRA_PASSWORD
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{ Accept = 'application/json'; Authorization = "Basic $token"; 'User-Agent' = 'pr-jira-review-skill' }
}

function Invoke-JsonGet([string]$Url, [hashtable]$Headers) {
    try { return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get } catch { throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message) }
}

function Load-MockBundle([string]$Path) {
    return Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json -Depth 100
}

function Get-JiraKeys([object]$Bundle) {
    $texts = [System.Collections.Generic.List[string]]::new()
    if ($Bundle.pull.title) { [void]$texts.Add([string]$Bundle.pull.title) }
    if ($Bundle.pull.body) { [void]$texts.Add([string]$Bundle.pull.body) }
    if ($Bundle.pull.head.ref) { [void]$texts.Add([string]$Bundle.pull.head.ref) }
    foreach ($commit in @($Bundle.commits)) {
        if ($commit.commit.message) { [void]$texts.Add([string]$commit.commit.message) }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($text in $texts) {
        foreach ($match in [regex]::Matches($text, '\b([A-Z][A-Z0-9]+-\d+)\b')) {
            $key = $match.Groups[1].Value
            if ($seen.Add($key)) { [void]$keys.Add($key) }
        }
    }
    return @($keys)
}

function Fetch-GitHubBundle([hashtable]$PrRef) {
    $base = Get-GitHubApiBase $PrRef.Host
    $repoPath = "/repos/$($PrRef.Owner)/$($PrRef.Repo)"
    $prPath = "$repoPath/pulls/$($PrRef.Number)"
    $issuePath = "$repoPath/issues/$($PrRef.Number)"
    $headers = Get-GitHubHeaders
    return @{
        pr_url = $PrRef.Url
        pull = Invoke-JsonGet "$base$prPath" $headers
        files = @(Invoke-JsonGet "$base$prPath/files?per_page=100" $headers)
        commits = @(Invoke-JsonGet "$base$prPath/commits?per_page=100" $headers)
        issue_comments = @(Invoke-JsonGet "$base$issuePath/comments?per_page=100" $headers)
        review_comments = @(Invoke-JsonGet "$base$prPath/comments?per_page=100" $headers)
    }
}

function Fetch-JiraIssues([string[]]$Keys) {
    if (-not $env:JIRA_BASE_URL) { throw 'Live mode requires JIRA_BASE_URL.' }
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

function Get-Orchestration([string]$RequestedMode, [string]$ModeUsed, [string]$ResolvedPromptText, [object]$Pull, [string[]]$JiraKeys) {
    $reasons = @()
    $changedFiles = [int]($Pull.changed_files ?? 0)
    $churn = [int]($Pull.churn ?? ([int]($Pull.additions ?? 0) + [int]($Pull.deletions ?? 0)))
    if ($RequestedMode -in @('real', 'auto')) { $reasons += 'Live or live-capable mode benefits from parallel context gathering.' }
    if ($changedFiles -gt 15 -or $churn -ge 600) { $reasons += 'Large PR size crosses the threshold for parallel analysis.' }
    if ($JiraKeys.Count -gt 1) { $reasons += 'Multiple Jira keys were detected and can be investigated independently.' }
    if ($ResolvedPromptText -and $ResolvedPromptText -match '\b(subagent|parallel|deep|depth|thorough)\b') { $reasons += 'The user explicitly asked for deeper or parallel review behavior.' }
    $useSubagents = ($reasons.Count -gt 0 -and $ModeUsed -ne 'mock-fallback')
    return [ordered]@{
        use_subagents = $useSubagents
        requested_mode = $RequestedMode
        mode_used = $ModeUsed
        reasons = if ($reasons.Count -gt 0) { $reasons } else { @('Run locally in a single thread for this request.') }
        agents = if ($useSubagents) {
            @(
                @{ name = 'Agent A'; role = 'GitHub Context Worker'; responsibility = 'Fetch PR metadata, files, commits, and comments.' },
                @{ name = 'Agent B'; role = 'Jira Context Worker'; responsibility = 'Extract Jira keys and gather issue context in parallel.' },
                @{ name = 'Agent C'; role = 'Review Analysis Worker'; responsibility = 'Analyze the combined evidence once context workers complete.' }
            )
        } else {
            @()
        }
    }
}

try {
    $resolvedMock = if ($MockData) { $MockData } else { Get-DefaultMockDataPath }
    $resolvedUrl = if ($PrUrl) { $PrUrl } else { Get-PrUrlFromText $PromptText }
    if (-not $resolvedUrl -and $Mode -ne 'mock') { throw 'No PR URL found. Provide --PrUrl or include a PR URL in --PromptText.' }
    if ($Mode -eq 'mock') {
        $modeUsed = 'mock'
        $bundle = Load-MockBundle $resolvedMock
    } else {
        try {
            $githubBundle = Fetch-GitHubBundle (Parse-PrUrl $resolvedUrl)
            $keys = Get-JiraKeys $githubBundle
            $jiraIssues = if ($keys.Count -gt 0) { Fetch-JiraIssues $keys } else { [ordered]@{} }
            $bundle = [ordered]@{}
            foreach ($entry in $githubBundle.GetEnumerator()) { $bundle[$entry.Key] = $entry.Value }
            $bundle.jira_keys = $keys
            $bundle.jira_issues = $jiraIssues
            $modeUsed = 'real'
        } catch {
            if ($Mode -ne 'auto') { throw }
            $modeUsed = 'mock-fallback'
            $bundle = Load-MockBundle $resolvedMock
        }
    }

    $tempBundle = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.json')
    try {
        $bundle | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 $tempBundle
        $writerPath = Join-Path $PSScriptRoot 'review_writer.ps1'
        $writerParams = @{ InputPath = $tempBundle; OutputFormat = 'json' }
        if ($DraftPath) { $writerParams.DraftPath = $DraftPath }
        if ($modeUsed) { $writerParams.ModeUsed = $modeUsed }
        if ($PromptText) { $writerParams.PromptText = $PromptText }
        $report = (& $writerPath @writerParams | Out-String) | ConvertFrom-Json -Depth 100
        $report | Add-Member -NotePropertyName orchestration -NotePropertyValue (Get-Orchestration $Mode $modeUsed $PromptText $report.pull @($report.jira_keys)) -Force
        $report | Add-Member -NotePropertyName publish_target -NotePropertyValue @{ pr_url = $report.pr_url; managed_marker = $ManagedMarker } -Force
        if ($OutputFormat -eq 'json') {
            $report | ConvertTo-Json -Depth 100
        } elseif ($DraftPath -and (Test-Path $DraftPath)) {
            Get-Content -Raw -Encoding UTF8 $DraftPath
        } else {
            $markdownParams = @{ InputPath = $tempBundle; OutputFormat = 'markdown' }
            if ($modeUsed) { $markdownParams.ModeUsed = $modeUsed }
            if ($PromptText) { $markdownParams.PromptText = $PromptText }
            & $writerPath @markdownParams
        }
    } finally {
        if (Test-Path $tempBundle) { Remove-Item $tempBundle -Force }
    }
} catch {
    Fail $_.Exception.Message
}





