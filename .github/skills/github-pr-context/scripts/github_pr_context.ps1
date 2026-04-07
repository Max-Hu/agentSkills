param(
    [string]$PrUrl,
    [string]$PromptText,
    [ValidateSet("auto", "real")]
    [string]$Mode = "auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function ConvertFrom-JsonCompat([string]$Json) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -Depth 100
    }
    return $Json | ConvertFrom-Json
}

function Get-PrUrlFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $match = [regex]::Match($Text, 'https?://[^\s]+/[^/\s]+/[^/\s]+/pull/\d+')
    if ($match.Success) {
        return $match.Value
    }
    return $null
}

function Parse-PrUrl([string]$Url) {
    try {
        $uri = [Uri]$Url
    } catch {
        throw "Unsupported PR URL: $Url"
    }
    $parts = $uri.AbsolutePath.Trim("/").Split("/")
    if ($parts.Length -ne 4 -or $parts[2] -ne "pull") {
        throw "Unsupported PR URL: $Url"
    }
    return @{
        Host = $uri.Host
        Owner = $parts[0]
        Repo = $parts[1]
        Number = [int]$parts[3]
        Url = $Url
    }
}

function Get-GitHubApiBase([string]$HostName) {
    if ($env:GITHUB_API_BASE_URL) {
        return $env:GITHUB_API_BASE_URL.TrimEnd("/")
    }
    if ($HostName.ToLowerInvariant() -eq "github.com") {
        return "https://api.github.com"
    }
    return "https://$HostName/api/v3"
}

function Get-GitHubHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "github-pr-context-skill"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
}

function Invoke-JsonGet([string]$Url, [hashtable]$Headers) {
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
    } catch {
        throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message)
    }
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

try {
    $resolvedUrl = if ($PrUrl) { $PrUrl } else { Get-PrUrlFromText $PromptText }
    if (-not $resolvedUrl) {
        throw "No PR URL found. Provide --PrUrl or include a PR URL in --PromptText."
    }
    $modeUsed = "real"
    $bundle = Fetch-GitHubBundle (Parse-PrUrl $resolvedUrl)

    $payload = [ordered]@{ mode_used = $modeUsed }
    foreach ($entry in $bundle.GetEnumerator()) {
        $payload[$entry.Key] = $entry.Value
    }
    $payload | ConvertTo-Json -Depth 100
} catch {
    Fail $_.Exception.Message
}

