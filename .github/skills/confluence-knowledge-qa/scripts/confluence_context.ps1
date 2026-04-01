param(
    [string[]]$PageUrls,
    [string]$PromptText,
    [ValidateSet("real", "mock")]
    [string]$Mode = "real",
    [ValidateSet("append", "replace")]
    [string]$MergeMode = "append",
    [switch]$Refresh,
    [switch]$ClearSession,
    [string]$CacheRoot
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

function Get-DefaultCacheRoot {
    if ($CacheRoot) {
        return $CacheRoot
    }
    if ($env:TEMP) {
        return Join-Path $env:TEMP "codex-confluence-knowledge-qa"
    }
    return Join-Path $PWD.Path "codex-confluence-knowledge-qa"
}

function Get-DefaultMockDataPath {
    return Join-Path $PSScriptRoot "..\assets\mock\sample-pages.json"
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-JsonFile([string]$Path) {
    return ConvertFrom-JsonCompat (Get-Content -Raw -Encoding UTF8 $Path)
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $Value | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 $Path
}

function Normalize-Url([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }
    return $Url.Trim().TrimEnd('.', ',', ';', ')', ']', '>')
}

function Get-ConfluenceUrlsFromPrompt([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }
    $matches = [regex]::Matches($Text, 'https?://[^\s''"")\]>]+')
    $urls = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($match in $matches) {
        $candidate = Normalize-Url $match.Value
        if ($candidate -and $seen.Add($candidate)) {
            [void]$urls.Add($candidate)
        }
    }
    return @($urls)
}

function Get-ConfluenceApiBaseUri {
    if (-not $env:CONFLUENCE_API_BASE_URL) {
        throw "Live mode requires CONFLUENCE_API_BASE_URL."
    }
    try {
        return [Uri]($env:CONFLUENCE_API_BASE_URL.TrimEnd('/'))
    } catch {
        throw "Invalid CONFLUENCE_API_BASE_URL: $($env:CONFLUENCE_API_BASE_URL)"
    }
}

function Get-ConfluenceSiteRoot([Uri]$ApiBaseUri) {
    $path = $ApiBaseUri.AbsolutePath.TrimEnd('/')
    $index = $path.ToLowerInvariant().IndexOf('/rest/api')
    if ($index -lt 0) {
        throw "CONFLUENCE_API_BASE_URL must end with /rest/api or include /rest/api in its path."
    }
    $root = $path.Substring(0, $index)
    if ([string]::IsNullOrWhiteSpace($root)) {
        return "/"
    }
    return $root
}

function Test-SameOrigin([Uri]$PageUri, [Uri]$ApiBaseUri) {
    return $PageUri.Scheme -eq $ApiBaseUri.Scheme -and $PageUri.Host -eq $ApiBaseUri.Host -and $PageUri.Port -eq $ApiBaseUri.Port
}

function Parse-ConfluencePageRef([string]$Url, [Uri]$ApiBaseUri = $null) {
    $resolvedUrl = Normalize-Url $Url
    if (-not $resolvedUrl) {
        throw "Encountered an empty Confluence URL."
    }
    try {
        $uri = [Uri]$resolvedUrl
    } catch {
        throw "Unsupported Confluence URL: $resolvedUrl"
    }

    if ($ApiBaseUri) {
        if (-not (Test-SameOrigin $uri $ApiBaseUri)) {
            throw "Confluence URL must use the same scheme, host, and port as CONFLUENCE_API_BASE_URL: $resolvedUrl"
        }
        $siteRoot = Get-ConfluenceSiteRoot $ApiBaseUri
        if ($siteRoot -ne "/" -and -not $uri.AbsolutePath.StartsWith($siteRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Confluence URL must stay under the same site root as CONFLUENCE_API_BASE_URL: $resolvedUrl"
        }
    }

    $pageId = $null
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    if ($query['pageId']) {
        $pageId = $query['pageId']
    }
    if (-not $pageId) {
        $pathMatch = [regex]::Match($uri.AbsolutePath, '/pages/(\d+)(?:/|$)')
        if ($pathMatch.Success) {
            $pageId = $pathMatch.Groups[1].Value
        }
    }
    if (-not $pageId) {
        throw "Could not extract a Confluence pageId from URL: $resolvedUrl"
    }

    return [ordered]@{
        id = [string]$pageId
        url = $resolvedUrl
    }
}

function Get-BasicAuthHeaders {
    if (-not $env:CONFLUENCE_USERNAME -or -not $env:CONFLUENCE_PASSWORD) {
        throw "Live mode requires CONFLUENCE_USERNAME and CONFLUENCE_PASSWORD."
    }
    $pair = "{0}:{1}" -f $env:CONFLUENCE_USERNAME, $env:CONFLUENCE_PASSWORD
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{
        Accept = "application/json"
        Authorization = "Basic $token"
        "User-Agent" = "confluence-knowledge-qa-skill"
    }
}

function Invoke-ConfluenceJsonGet([string]$Url, [hashtable]$Headers) {
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
    } catch {
        throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message)
    }
}

function Convert-HtmlFragmentToText([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ""
    }

    $text = $Html
    $text = [regex]::Replace($text, '(?is)<br\s*/?>', "`n")
    $text = [regex]::Replace($text, '(?is)</(p|div|section|article|tr|table|ul|ol|blockquote)>', "`n")
    $text = [regex]::Replace($text, '(?is)<li[^>]*>', '- ')
    $text = [regex]::Replace($text, '(?is)</li>', "`n")
    $text = [regex]::Replace($text, '(?is)<(td|th)[^>]*>', '| ')
    $text = [regex]::Replace($text, '(?is)</(td|th)>', ' ')
    $text = [regex]::Replace($text, '(?is)<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace '[ \t\f\v]+', ' '
    $text = $text -replace ' *\r?\n *', "`n"
    $text = $text -replace "(`n){3,}", "`n`n"
    return $text.Trim()
}

function Get-HeadingText([string]$Html) {
    return Convert-HtmlFragmentToText $Html
}

function Get-ConfluenceSections([string]$PageTitle, [string]$StorageValue) {
    $sections = [System.Collections.Generic.List[object]]::new()
    $headingRegex = [regex]'(?is)<h([1-6])[^>]*>(.*?)</h\1>'
    $matches = @($headingRegex.Matches($StorageValue))

    if ($matches.Count -eq 0) {
        $bodyText = Convert-HtmlFragmentToText $StorageValue
        if ($bodyText) {
            [void]$sections.Add([ordered]@{
                heading_path = $PageTitle
                text = $bodyText
            })
        }
        return @($sections)
    }

    $introHtml = $StorageValue.Substring(0, $matches[0].Index)
    $introText = Convert-HtmlFragmentToText $introHtml
    if ($introText) {
        [void]$sections.Add([ordered]@{
            heading_path = $PageTitle
            text = $introText
        })
    }

    $stack = @()
    for ($i = 0; $i -lt $matches.Count; $i++) {
        $current = $matches[$i]
        $level = [int]$current.Groups[1].Value
        $headingText = Get-HeadingText $current.Groups[2].Value
        if (-not $headingText) {
            continue
        }

        if ($stack.Count -ge $level) {
            if ($level -le 1) {
                $stack = @()
            } else {
                $stack = @($stack[0..($level - 2)])
            }
        }
        $stack += $headingText

        $contentStart = $current.Index + $current.Length
        $contentEnd = if ($i -lt ($matches.Count - 1)) { $matches[$i + 1].Index } else { $StorageValue.Length }
        $fragment = $StorageValue.Substring($contentStart, $contentEnd - $contentStart)
        $text = Convert-HtmlFragmentToText $fragment
        if (-not $text) {
            continue
        }

        [void]$sections.Add([ordered]@{
            heading_path = (($stack | Where-Object { $_ }) -join ' > ')
            text = $text
        })
    }

    return @($sections)
}

function Convert-ApiContentToPageBundle([object]$ApiContent, [string]$ResolvedUrl) {
    $contentText = Convert-HtmlFragmentToText $ApiContent.body.storage.value
    $rawSections = Get-ConfluenceSections $ApiContent.title $ApiContent.body.storage.value
    $sections = foreach ($section in $rawSections) {
        [ordered]@{
            page_id = [string]$ApiContent.id
            page_title = [string]$ApiContent.title
            heading_path = [string]$section.heading_path
            text = [string]$section.text
        }
    }

    return [ordered]@{
        url = $ResolvedUrl
        id = [string]$ApiContent.id
        title = [string]$ApiContent.title
        space_key = if ($ApiContent.space.key) { [string]$ApiContent.space.key } else { '' }
        version = if ($ApiContent.version.number) { [int]$ApiContent.version.number } else { 0 }
        ancestor_titles = @($ApiContent.ancestors | ForEach-Object { [string]$_.title })
        content_text = $contentText
        sections = @($sections)
    }
}

function Get-MockPageIndex([string]$Path) {
    $payload = Read-JsonFile $Path
    $index = @{}
    foreach ($page in @($payload.pages)) {
        $ref = Parse-ConfluencePageRef $page.url
        $index[[string]$ref.id] = $page
    }
    return $index
}

function Get-PageFromMock([object]$PageRef, [hashtable]$MockIndex) {
    if (-not $MockIndex.ContainsKey($PageRef.id)) {
        throw "Mock data does not contain pageId $($PageRef.id)."
    }
    return Convert-ApiContentToPageBundle $MockIndex[$PageRef.id].content $PageRef.url
}

function Get-PageFromApi([object]$PageRef, [Uri]$ApiBaseUri, [hashtable]$Headers) {
    $base = $ApiBaseUri.AbsoluteUri.TrimEnd('/')
    $safeId = [Uri]::EscapeDataString($PageRef.id)
    $url = "$base/content/$safeId?expand=body.storage,version,space,ancestors"
    $content = Invoke-ConfluenceJsonGet $url $Headers
    return Convert-ApiContentToPageBundle $content $PageRef.url
}

function Get-ManifestPath([string]$ResolvedCacheRoot) {
    return Join-Path $ResolvedCacheRoot 'session-manifest.json'
}

function Get-PageCachePath([string]$ResolvedCacheRoot, [string]$PageId) {
    return Join-Path $ResolvedCacheRoot ("page-{0}.json" -f $PageId)
}

function Read-Manifest([string]$ManifestPath) {
    if (-not (Test-Path $ManifestPath)) {
        return $null
    }
    return Read-JsonFile $ManifestPath
}

function Save-Manifest([string]$ManifestPath, [object]$Manifest) {
    Write-JsonFile $ManifestPath $Manifest
}

function Get-RequestedPageRefs([string[]]$ResolvedUrls, [string]$Mode, [Uri]$ApiBaseUri = $null) {
    $refs = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($url in @($ResolvedUrls)) {
        $parsed = if ($Mode -eq 'real') { Parse-ConfluencePageRef $url $ApiBaseUri } else { Parse-ConfluencePageRef $url }
        if ($seen.Add([string]$parsed.id)) {
            [void]$refs.Add($parsed)
        }
    }
    return @($refs)
}

function Get-ManifestPageRefs([object]$Manifest, [string]$Mode, [Uri]$ApiBaseUri = $null) {
    if ($null -eq $Manifest) {
        return @()
    }
    $refs = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($Manifest.pages)) {
        $parsed = if ($Mode -eq 'real') { Parse-ConfluencePageRef $page.url $ApiBaseUri } else { Parse-ConfluencePageRef $page.url }
        [void]$refs.Add($parsed)
    }
    return @($refs)
}

function New-EmptyManifest {
    return [ordered]@{
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        pages = @()
    }
}

function Resolve-ActivePages(
    [object]$ExistingManifest,
    [object[]]$RequestedRefs,
    [string]$ResolvedCacheRoot,
    [string]$Mode,
    [string]$ResolvedMergeMode,
    [bool]$ShouldRefresh,
    [bool]$ShouldClear,
    [hashtable]$MockIndex,
    [Uri]$ApiBaseUri = $null,
    [hashtable]$Headers = $null
) {
    $manifestMap = @{}
    $orderedIds = [System.Collections.Generic.List[string]]::new()

    if (-not $ShouldClear -and -not ($ResolvedMergeMode -eq 'replace' -and $RequestedRefs.Count -gt 0) -and $ExistingManifest) {
        foreach ($page in @($ExistingManifest.pages)) {
            $pageId = [string]$page.id
            $manifestMap[$pageId] = $page
            [void]$orderedIds.Add($pageId)
        }
    }

    if ($ResolvedMergeMode -eq 'replace' -and $RequestedRefs.Count -gt 0) {
        $manifestMap = @{}
        $orderedIds = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($pageRef in $RequestedRefs) {
        $pageId = [string]$pageRef.id
        $cachePath = Get-PageCachePath $ResolvedCacheRoot $pageId
        $needsFetch = $ShouldRefresh -or -not $manifestMap.ContainsKey($pageId) -or -not (Test-Path $cachePath)

        if ($needsFetch) {
            $pageBundle = if ($Mode -eq 'mock') {
                Get-PageFromMock $pageRef $MockIndex
            } else {
                Get-PageFromApi $pageRef $ApiBaseUri $Headers
            }
            Write-JsonFile $cachePath $pageBundle
        } else {
            $pageBundle = Read-JsonFile $cachePath
            $pageBundle.url = $pageRef.url
        }

        $manifestEntry = [ordered]@{
            id = $pageBundle.id
            url = $pageRef.url
            title = $pageBundle.title
            version = $pageBundle.version
            cache_path = $cachePath
            fetched_at_utc = [DateTime]::UtcNow.ToString('o')
        }
        $manifestMap[$pageId] = $manifestEntry
        if (-not $orderedIds.Contains($pageId)) {
            [void]$orderedIds.Add($pageId)
        }
    }

    $activeEntries = foreach ($pageId in $orderedIds) {
        if ($manifestMap.ContainsKey($pageId)) {
            $manifestMap[$pageId]
        }
    }

    return @($activeEntries)
}

function Build-OutputBundle([string]$ModeUsed, [string]$ManifestPath, [object[]]$ManifestEntries) {
    $pages = [System.Collections.Generic.List[object]]::new()
    $combinedSections = [System.Collections.Generic.List[object]]::new()
    $combinedTextParts = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($ManifestEntries)) {
        $pageBundle = Read-JsonFile $entry.cache_path
        $pageBundle.url = $entry.url
        [void]$pages.Add($pageBundle)
        foreach ($section in @($pageBundle.sections)) {
            [void]$combinedSections.Add($section)
        }
        if ($pageBundle.content_text) {
            $block = "## {0}`n{1}" -f $pageBundle.title, $pageBundle.content_text
            [void]$combinedTextParts.Add($block.Trim())
        }
    }

    return [ordered]@{
        mode_used = $ModeUsed
        session_manifest_path = $ManifestPath
        page_count = $pages.Count
        pages = @($pages)
        combined_content_text = (($combinedTextParts -join "`n`n").Trim())
        combined_sections = @($combinedSections)
    }
}

try {
    Add-Type -AssemblyName System.Web | Out-Null

    $resolvedCacheRoot = Get-DefaultCacheRoot
    Ensure-Directory $resolvedCacheRoot
    $manifestPath = Get-ManifestPath $resolvedCacheRoot
    $existingManifest = Read-Manifest $manifestPath

    $promptUrls = Get-ConfluenceUrlsFromPrompt $PromptText
    $directUrls = @()
    foreach ($url in @($PageUrls)) {
        $normalized = Normalize-Url $url
        if ($normalized) {
            $directUrls += $normalized
        }
    }
    $resolvedUrls = @($directUrls + $promptUrls)

    $apiBaseUri = $null
    $headers = $null
    $mockIndex = @{}
    if ($Mode -eq 'mock') {
        $mockIndex = Get-MockPageIndex (Get-DefaultMockDataPath)
    } else {
        $apiBaseUri = Get-ConfluenceApiBaseUri
        $headers = Get-BasicAuthHeaders
    }

    $requestedRefs = @(Get-RequestedPageRefs $resolvedUrls $Mode $apiBaseUri)
    if ($requestedRefs.Count -eq 0 -and $Refresh -and $existingManifest) {
        $requestedRefs = @(Get-ManifestPageRefs $existingManifest $Mode $apiBaseUri)
    }

    if ($ClearSession -and $requestedRefs.Count -eq 0) {
        $emptyManifest = New-EmptyManifest
        Save-Manifest $manifestPath $emptyManifest
        ([ordered]@{
            mode_used = $Mode
            session_manifest_path = $manifestPath
            page_count = 0
            pages = @()
            combined_content_text = ''
            combined_sections = @()
        }) | ConvertTo-Json -Depth 100
        exit 0
    }

    if ($requestedRefs.Count -eq 0 -and -not $existingManifest) {
        throw 'No Confluence page URLs were provided and no active session manifest exists.'
    }

    $activeEntries = @(Resolve-ActivePages $existingManifest $requestedRefs $resolvedCacheRoot $Mode $MergeMode ([bool]$Refresh) ([bool]$ClearSession) $mockIndex $apiBaseUri $headers)

    if ($requestedRefs.Count -eq 0 -and -not $ClearSession) {
        $activeEntries = @($existingManifest.pages)
    }

    $manifest = [ordered]@{
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        pages = @($activeEntries)
    }
    Save-Manifest $manifestPath $manifest

    $bundle = Build-OutputBundle $Mode $manifestPath $activeEntries
    $bundle | ConvertTo-Json -Depth 100
} catch {
    Fail $_.Exception.Message
}


