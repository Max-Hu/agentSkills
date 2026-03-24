param(
    [string]$PrUrl,
    [string]$DraftPath,
    [ValidateSet("real", "mock")]
    [string]$Mode = "real"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ManagedMarker = "<!-- pr-review-report:managed -->"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Parse-PrUrl([string]$Url) {
    try {
        $uri = [Uri]$Url
    } catch {
        throw "Unsupported PR URL: $Url"
    }
    $parts = $uri.AbsolutePath.Trim('/').Split('/')
    if ($parts.Length -ne 4 -or $parts[2] -ne 'pull') {
        throw "Unsupported PR URL: $Url"
    }
    return @{ Host = $uri.Host; Owner = $parts[0]; Repo = $parts[1]; Number = [int]$parts[3]; Url = $Url }
}

function Get-GitHubApiBase([string]$HostName) {
    if ($env:GITHUB_API_BASE_URL) { return $env:GITHUB_API_BASE_URL.TrimEnd('/') }
    if ($HostName.ToLowerInvariant() -eq 'github.com') { return 'https://api.github.com' }
    return "https://$HostName/api/v3"
}

function Get-GitHubHeaders {
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'pr-review-publisher-skill'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)" }
    return $headers
}

function Invoke-GitHubJson([string]$Url, [string]$Method, [object]$Body = $null) {
    $params = @{ Uri = $Url; Headers = (Get-GitHubHeaders); Method = $Method }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
        $params.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message)
    }
}

function Get-ManagedBody([string]$Markdown) {
    $body = $Markdown.Trim()
    if (-not $body) { throw 'Review draft is empty.' }
    if ($body.Length -gt 65000) { throw 'Review draft exceeds the GitHub issue comment size limit.' }
    return "$ManagedMarker`n`n$body`n"
}

try {
    if (-not $PrUrl) { throw 'Provide --PrUrl with the pull request URL.' }
    if (-not $DraftPath) { throw 'Provide -DraftPath with the Markdown draft path.' }
    $markdown = Get-Content -Raw -Encoding UTF8 $DraftPath
    $managedBody = Get-ManagedBody $markdown
    if ($Mode -eq 'mock') {
        [ordered]@{
            comment_id = 999999
            comment_url = "$PrUrl#issuecomment-mock"
            action = 'created'
            marker_found = $false
            pr_url = $PrUrl
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    $prRef = Parse-PrUrl $PrUrl
    $base = Get-GitHubApiBase $prRef.Host
    $existing = $null
    $comments = @(Invoke-GitHubJson "$base/repos/$($prRef.Owner)/$($prRef.Repo)/issues/$($prRef.Number)/comments?per_page=100" 'GET')
    foreach ($comment in @($comments | Sort-Object id -Descending)) {
        if ([string]$comment.body -like "*$ManagedMarker*") {
            $existing = $comment
            break
        }
    }
    if ($existing) {
        $updated = Invoke-GitHubJson "$base/repos/$($prRef.Owner)/$($prRef.Repo)/issues/comments/$($existing.id)" 'PATCH' @{ body = $managedBody }
        [ordered]@{
            comment_id = [int]($updated.id ?? $existing.id)
            comment_url = if ($updated.html_url) { $updated.html_url } else { $existing.html_url }
            action = 'updated'
            marker_found = $true
            pr_url = $PrUrl
        } | ConvertTo-Json -Depth 20
    } else {
        $created = Invoke-GitHubJson "$base/repos/$($prRef.Owner)/$($prRef.Repo)/issues/$($prRef.Number)/comments" 'POST' @{ body = $managedBody }
        [ordered]@{
            comment_id = if ($created.id) { [int]$created.id } else { $null }
            comment_url = $created.html_url
            action = 'created'
            marker_found = $false
            pr_url = $PrUrl
        } | ConvertTo-Json -Depth 20
    }
} catch {
    Fail $_.Exception.Message
}


