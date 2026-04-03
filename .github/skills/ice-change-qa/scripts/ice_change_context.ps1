param(
    [string[]]$Ids,
    [string]$PromptText,
    [ValidateSet("real", "mock")]
    [string]$Mode = "real",
    [ValidateSet("append", "replace")]
    [string]$MergeMode = "append",
    [switch]$IncludeUpdates,
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

function ConvertTo-JsonText([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return ($Value | ConvertTo-Json -Depth 100)
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

function Get-PropertyValue([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Get-DefaultCacheRoot {
    if ($CacheRoot) {
        return $CacheRoot
    }
    if ($env:TEMP) {
        return Join-Path $env:TEMP 'codex-ice-change-qa'
    }
    return Join-Path $PWD.Path 'codex-ice-change-qa'
}

function Get-DefaultMockDataPath {
    return Join-Path $PSScriptRoot '..\assets\mock\sample-changes.json'
}

function Normalize-Token([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    return $Value.Trim().TrimEnd('.', ',', ';', ')', ']', '>')
}

function Test-ShouldFetchUpdates([string]$Text, [bool]$RequestedByFlag) {
    if ($RequestedByFlag) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    return [regex]::IsMatch(
        $Text,
        '(?i)\bupdates?\b|\bupdated\b|更新|更新历史|最新更新|最近更新|变更历史|谁更新|操作者|updater'
    )
}

function Try-Parse-ChangeUrl([string]$Value) {
    $candidate = Normalize-Token $Value
    if (-not $candidate -or -not $candidate.StartsWith('http')) {
        return $null
    }
    try {
        $uri = [Uri]$candidate
    } catch {
        return $null
    }

    $match = [regex]::Match($uri.AbsolutePath, '/changes/([^/?#]+)(?:/|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return [ordered]@{
        id = [string]$match.Groups[1].Value
        reference = $candidate
        kind = 'url'
    }
}

function Add-RequestedRef(
    [System.Collections.Generic.List[object]]$Refs,
    [System.Collections.Generic.HashSet[string]]$Seen,
    [string]$Id,
    [string]$Reference,
    [string]$Kind
) {
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return
    }

    $safeId = [string]$Id.Trim()
    if ($Seen.Add($safeId)) {
        [void]$Refs.Add([ordered]@{
            id = $safeId
            reference = if ($Reference) { $Reference } else { $safeId }
            kind = if ($Kind) { $Kind } else { 'id' }
        })
    }
}

function Get-RequestedChangeRefs([string[]]$InputIds, [string]$InputPrompt) {
    $refs = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($value in @($InputIds)) {
        foreach ($token in ($value -split '[,\s]+')) {
            $normalized = Normalize-Token $token
            if (-not $normalized) {
                continue
            }

            $parsedUrl = Try-Parse-ChangeUrl $normalized
            if ($parsedUrl) {
                Add-RequestedRef $refs $seen $parsedUrl.id $parsedUrl.reference $parsedUrl.kind
                continue
            }

            if ($normalized -match '^[0-9]+$') {
                Add-RequestedRef $refs $seen $normalized $normalized 'id'
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($InputPrompt)) {
        $urlMatches = [regex]::Matches($InputPrompt, 'https?://[^\s''"\)\]>]+')
        foreach ($match in $urlMatches) {
            $parsedUrl = Try-Parse-ChangeUrl $match.Value
            if ($parsedUrl) {
                Add-RequestedRef $refs $seen $parsedUrl.id $parsedUrl.reference $parsedUrl.kind
            }
        }

        $promptWithoutUrls = [regex]::Replace($InputPrompt, 'https?://[^\s''"\)\]>]+', ' ')
        $idMatches = [regex]::Matches($promptWithoutUrls, '\b\d+\b')
        foreach ($match in $idMatches) {
            Add-RequestedRef $refs $seen $match.Value $match.Value 'id'
        }
    }

    return @($refs)
}

function Get-IceApiBaseUri {
    if (-not $env:ICE_API_BASE_URL) {
        throw 'Live mode requires ICE_API_BASE_URL.'
    }
    try {
        $uri = [Uri]($env:ICE_API_BASE_URL.TrimEnd('/'))
    } catch {
        throw "Invalid ICE_API_BASE_URL: $($env:ICE_API_BASE_URL)"
    }
    if (-not $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant().EndsWith('/ice/api')) {
        throw 'ICE_API_BASE_URL must end with /ice/api.'
    }
    return $uri
}

function Get-BasicAuthHeaders {
    if (-not $env:ICE_USERNAME -or -not $env:ICE_PASSWORD) {
        throw 'Live mode requires ICE_USERNAME and ICE_PASSWORD.'
    }
    $pair = "{0}:{1}" -f $env:ICE_USERNAME, $env:ICE_PASSWORD
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{
        Accept = 'application/json'
        Authorization = "Basic $token"
        'User-Agent' = 'ice-change-qa-skill'
    }
}

function Invoke-IceJsonGet([string]$Url, [hashtable]$Headers) {
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
    } catch {
        throw ("Network error for {0}: {1}" -f $Url, $_.Exception.Message)
    }
}

function Get-ManifestPath([string]$ResolvedCacheRoot) {
    return Join-Path $ResolvedCacheRoot 'session-manifest.json'
}

function Get-ChangeCachePath([string]$ResolvedCacheRoot, [string]$ChangeId) {
    return Join-Path $ResolvedCacheRoot ("change-{0}.json" -f $ChangeId)
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

function New-EmptyManifest {
    return [ordered]@{
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        changes = @()
    }
}

function Get-ManifestChangeRefs([object]$Manifest) {
    if ($null -eq $Manifest) {
        return @()
    }

    $refs = [System.Collections.Generic.List[object]]::new()
    foreach ($change in @((Get-PropertyValue $Manifest 'changes'))) {
        $reference = Get-PropertyValue $change 'reference'
        $kind = Get-PropertyValue $change 'kind'
        [void]$refs.Add([ordered]@{
            id = [string](Get-PropertyValue $change 'id')
            reference = if ($reference) { [string]$reference } else { [string](Get-PropertyValue $change 'id') }
            kind = if ($kind) { [string]$kind } else { 'id' }
        })
    }
    return @($refs)
}

function Get-MockIndexes([string]$Path) {
    $payload = Read-JsonFile $Path
    $changeIndex = @{}
    foreach ($entry in @((Get-PropertyValue $payload 'changes'))) {
        $changeIndex[[string](Get-PropertyValue $entry 'id')] = $entry
    }
    $updateIndex = @{}
    foreach ($entry in @((Get-PropertyValue $payload 'updates'))) {
        $updateIndex[[string](Get-PropertyValue $entry 'changeId')] = $entry
    }
    $apiUserIndex = @{}
    foreach ($entry in @((Get-PropertyValue $payload 'apiUsers'))) {
        $apiUserIndex[[string](Get-PropertyValue $entry 'apiUserID')] = $entry
    }
    return [ordered]@{
        changes = $changeIndex
        updates = $updateIndex
        api_users = $apiUserIndex
    }
}

function Get-ChangeFromMock([string]$Id, [object]$MockIndexes) {
    if (-not $MockIndexes.changes.ContainsKey($Id)) {
        throw "Mock data does not contain change $Id."
    }
    $entry = $MockIndexes.changes[$Id]
    $errorText = Get-PropertyValue $entry 'error'
    if ($errorText) {
        throw [string]$errorText
    }
    return Get-PropertyValue $entry 'response'
}

function Get-UpdatesFromMock([string]$Id, [object]$MockIndexes) {
    if (-not $MockIndexes.updates.ContainsKey($Id)) {
        throw "Mock data does not contain updates for change $Id."
    }
    $entry = $MockIndexes.updates[$Id]
    $errorText = Get-PropertyValue $entry 'error'
    if ($errorText) {
        throw [string]$errorText
    }
    return Get-PropertyValue $entry 'response'
}

function Get-ApiUserFromMock([string]$ApiUserId, [object]$MockIndexes) {
    if (-not $MockIndexes.api_users.ContainsKey($ApiUserId)) {
        throw "Mock data does not contain apiUserID $ApiUserId."
    }
    $entry = $MockIndexes.api_users[$ApiUserId]
    $errorText = Get-PropertyValue $entry 'error'
    if ($errorText) {
        throw [string]$errorText
    }
    return Get-PropertyValue $entry 'response'
}

function Get-ChangeFromApi([string]$Id, [Uri]$ApiBaseUri, [hashtable]$Headers) {
    $base = $ApiBaseUri.AbsoluteUri.TrimEnd('/')
    $safeId = [Uri]::EscapeDataString($Id)
    return Invoke-IceJsonGet "$base/v4/changes/$safeId" $Headers
}

function Get-UpdatesFromApi([string]$Id, [Uri]$ApiBaseUri, [hashtable]$Headers) {
    $base = $ApiBaseUri.AbsoluteUri.TrimEnd('/')
    $safeId = [Uri]::EscapeDataString($Id)
    return Invoke-IceJsonGet "$base/v1/changes/$safeId/updates" $Headers
}

function Get-ApiUserFromApi([string]$ApiUserId, [Uri]$ApiBaseUri, [hashtable]$Headers) {
    $base = $ApiBaseUri.AbsoluteUri.TrimEnd('/')
    $safeId = [Uri]::EscapeDataString($ApiUserId)
    return Invoke-IceJsonGet "$base/v1/apiUsers?apiUserID=$safeId" $Headers
}

function Get-UpdateResults([object]$UpdatesResponse) {
    if ($null -eq $UpdatesResponse) {
        return @()
    }
    $results = Get-PropertyValue $UpdatesResponse 'results'
    if ($null -ne $results) {
        return @($results)
    }
    if ($UpdatesResponse -is [System.Collections.IEnumerable] -and -not ($UpdatesResponse -is [string])) {
        return @($UpdatesResponse)
    }
    return @()
}

function Get-ApiUserEntity([object]$ApiUserResponse, [string]$ApiUserId) {
    if ($null -eq $ApiUserResponse) {
        return $null
    }

    $results = Get-PropertyValue $ApiUserResponse 'results'
    if ($null -ne $results) {
        $resultArray = @($results)
        foreach ($item in $resultArray) {
            $itemApiUserId = Get-PropertyValue $item 'apiUserID'
            if ($itemApiUserId -and [string]$itemApiUserId -eq $ApiUserId) {
                return $item
            }
        }
        if ($resultArray.Count -gt 0) {
            return $resultArray[0]
        }
    }

    if ($ApiUserResponse -is [System.Collections.IEnumerable] -and -not ($ApiUserResponse -is [string])) {
        foreach ($item in @($ApiUserResponse)) {
            $itemApiUserId = Get-PropertyValue $item 'apiUserID'
            if ($itemApiUserId -and [string]$itemApiUserId -eq $ApiUserId) {
                return $item
            }
        }
    }

    return $ApiUserResponse
}

function Resolve-ApiUserDisplayName([object]$ApiUserResponse, [string]$FallbackId) {
    $entity = Get-ApiUserEntity $ApiUserResponse $FallbackId
    if ($null -eq $entity) {
        return $FallbackId
    }

    foreach ($propertyName in @('displayName', 'fullName', 'name', 'userName', 'username', 'email')) {
        $value = [string](Get-PropertyValue $entity $propertyName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $FallbackId
}

function New-ResolvedUpdatersObject([System.Collections.IDictionary]$ResolvedUpdaters) {
    if ($ResolvedUpdaters.Count -eq 0) {
        return [pscustomobject]@{}
    }
    return [pscustomobject]([ordered]@{} + $ResolvedUpdaters)
}

function New-ChangeOutput(
    [string]$Id,
    [object]$Change,
    [object]$Updates,
    [object]$ResolvedUpdaters,
    [string[]]$Warnings,
    [string[]]$Errors,
    [string]$Reference,
    [string]$Kind,
    [bool]$ShouldIncludeUpdates
) {
    $status = 'complete'
    if ((@($Warnings).Count -gt 0) -or (@($Errors).Count -gt 0)) {
        if ($null -ne $Change -or ($ShouldIncludeUpdates -and $null -ne $Updates)) {
            $status = 'partial'
        } else {
            $status = 'failed'
        }
    }

    return [ordered]@{
        id = $Id
        change = $Change
        updates = if ($ShouldIncludeUpdates) { $Updates } else { $null }
        resolved_updaters = if ($ShouldIncludeUpdates) { $ResolvedUpdaters } else { [pscustomobject]@{} }
        qa_source_text = (Build-QaSourceText $Id $Change $Updates $ResolvedUpdaters $ShouldIncludeUpdates)
        status = $status
        warnings = @($Warnings)
        errors = @($Errors)
        reference = $Reference
        kind = $Kind
    }
}

function Test-HasUpdateData([object]$ChangeBundle) {
    if ($null -eq $ChangeBundle) {
        return $false
    }

    $updates = Get-PropertyValue $ChangeBundle 'updates'
    if ($null -ne $updates) {
        return $true
    }

    $resolvedUpdaters = Get-PropertyValue $ChangeBundle 'resolved_updaters'
    if ($null -eq $resolvedUpdaters) {
        return $false
    }

    return @($resolvedUpdaters.PSObject.Properties).Count -gt 0
}

function Build-QaSourceText([string]$Id, [object]$Change, [object]$Updates, [object]$ResolvedUpdaters, [bool]$ShouldIncludeUpdates) {
    $parts = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $Change) {
        [void]$parts.Add(("## Change {0}`n{1}" -f $Id, (ConvertTo-JsonText $Change)).Trim())
    }

    if ($ShouldIncludeUpdates) {
        $updateResults = @(Get-UpdateResults $Updates)
        if ($updateResults.Count -gt 0) {
            [void]$parts.Add(("## Change {0} Updates`n{1}" -f $Id, (ConvertTo-JsonText $updateResults)).Trim())
        } elseif ($null -ne $Updates) {
            [void]$parts.Add(("## Change {0} Updates`n{1}" -f $Id, (ConvertTo-JsonText $Updates)).Trim())
        }

        $resolvedProperties = @($ResolvedUpdaters.PSObject.Properties)
        if ($resolvedProperties.Count -gt 0) {
            $lines = foreach ($property in $resolvedProperties) {
                "- {0}: {1}" -f $property.Name, [string]$property.Value
            }
            [void]$parts.Add(("## Change {0} Resolved Updaters`n{1}" -f $Id, ($lines -join "`n")).Trim())
        }
    }

    return (($parts -join "`n`n").Trim())
}

function Get-ChangeBundle(
    [object]$ChangeRef,
    [string]$Mode,
    [object]$MockIndexes,
    [bool]$ShouldIncludeUpdates,
    [Uri]$ApiBaseUri = $null,
    [hashtable]$Headers = $null
) {
    $id = [string](Get-PropertyValue $ChangeRef 'id')
    $change = $null
    $updates = $null
    $resolvedUpdaters = [ordered]@{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        $change = if ($Mode -eq 'mock') { Get-ChangeFromMock $id $MockIndexes } else { Get-ChangeFromApi $id $ApiBaseUri $Headers }
    } catch {
        [void]$errors.Add("change fetch failed: $($_.Exception.Message)")
    }

    if ($ShouldIncludeUpdates) {
        try {
            $updates = if ($Mode -eq 'mock') { Get-UpdatesFromMock $id $MockIndexes } else { Get-UpdatesFromApi $id $ApiBaseUri $Headers }
        } catch {
            [void]$errors.Add("updates fetch failed: $($_.Exception.Message)")
        }

        $updaterIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($update in @(Get-UpdateResults $updates)) {
            $updaterId = [string](Get-PropertyValue $update 'updaterApiUserID')
            if (-not [string]::IsNullOrWhiteSpace($updaterId)) {
                [void]$updaterIds.Add($updaterId)
            }
        }

        foreach ($updaterId in $updaterIds) {
            try {
                $apiUserResponse = if ($Mode -eq 'mock') { Get-ApiUserFromMock $updaterId $MockIndexes } else { Get-ApiUserFromApi $updaterId $ApiBaseUri $Headers }
                $resolvedUpdaters[$updaterId] = Resolve-ApiUserDisplayName $apiUserResponse $updaterId
            } catch {
                $resolvedUpdaters[$updaterId] = $updaterId
                [void]$warnings.Add("apiUser lookup failed for ${updaterId}: $($_.Exception.Message)")
            }
        }
    }

    $resolvedUpdatersObject = New-ResolvedUpdatersObject $resolvedUpdaters
    $changeOutputParams = @{
        Id = $id
        Change = $change
        Updates = $updates
        ResolvedUpdaters = $resolvedUpdatersObject
        Warnings = @($warnings.ToArray())
        Errors = @($errors.ToArray())
        Reference = [string](Get-PropertyValue $ChangeRef 'reference')
        Kind = [string](Get-PropertyValue $ChangeRef 'kind')
        ShouldIncludeUpdates = $ShouldIncludeUpdates
    }
    return New-ChangeOutput @changeOutputParams
}

function Resolve-ActiveChanges(
    [object]$ExistingManifest,
    [object[]]$RequestedRefs,
    [string]$ResolvedCacheRoot,
    [string]$Mode,
    [string]$ResolvedMergeMode,
    [bool]$ShouldIncludeUpdates,
    [bool]$ShouldRefresh,
    [bool]$ShouldClear,
    [object]$MockIndexes,
    [Uri]$ApiBaseUri = $null,
    [hashtable]$Headers = $null
) {
    $manifestMap = @{}
    $orderedIds = [System.Collections.Generic.List[string]]::new()

    if (-not $ShouldClear -and -not ($ResolvedMergeMode -eq 'replace' -and @($RequestedRefs).Count -gt 0) -and $ExistingManifest) {
        foreach ($change in @((Get-PropertyValue $ExistingManifest 'changes'))) {
            $changeId = [string](Get-PropertyValue $change 'id')
            $manifestMap[$changeId] = $change
            [void]$orderedIds.Add($changeId)
        }
    }

    if ($ResolvedMergeMode -eq 'replace' -and @($RequestedRefs).Count -gt 0) {
        $manifestMap = @{}
        $orderedIds = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($changeRef in @($RequestedRefs)) {
        $changeId = [string](Get-PropertyValue $changeRef 'id')
        $cachePath = Get-ChangeCachePath $ResolvedCacheRoot $changeId
        $cachedBundle = $null
        if (Test-Path $cachePath) {
            $cachedBundle = Read-JsonFile $cachePath
        }

        $needsFetch = $ShouldRefresh -or -not $manifestMap.ContainsKey($changeId) -or -not (Test-Path $cachePath)
        if (-not $needsFetch -and $ShouldIncludeUpdates -and -not (Test-HasUpdateData $cachedBundle)) {
            $needsFetch = $true
        }

        if ($needsFetch) {
            $changeBundle = Get-ChangeBundle $changeRef $Mode $MockIndexes $ShouldIncludeUpdates $ApiBaseUri $Headers
            Write-JsonFile $cachePath $changeBundle
        } else {
            $changeBundle = $cachedBundle
        }

        $manifestEntry = [ordered]@{
            id = [string](Get-PropertyValue $changeBundle 'id')
            reference = [string](Get-PropertyValue $changeRef 'reference')
            kind = [string](Get-PropertyValue $changeRef 'kind')
            cache_path = $cachePath
            fetched_at_utc = [DateTime]::UtcNow.ToString('o')
            status = [string](Get-PropertyValue $changeBundle 'status')
        }
        $manifestMap[$changeId] = $manifestEntry
        if (-not $orderedIds.Contains($changeId)) {
            [void]$orderedIds.Add($changeId)
        }
    }

    $activeEntries = foreach ($changeId in $orderedIds) {
        if ($manifestMap.ContainsKey($changeId)) {
            $manifestMap[$changeId]
        }
    }

    return @($activeEntries)
}

function Build-OutputBundle([string]$ModeUsed, [string]$ManifestPath, [object[]]$ManifestEntries, [bool]$ShouldIncludeUpdates) {
    $changes = [System.Collections.Generic.List[object]]::new()
    $changeTextParts = [System.Collections.Generic.List[string]]::new()
    $updateTextParts = [System.Collections.Generic.List[string]]::new()
    $qaTextParts = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($ManifestEntries)) {
        $cachePath = [string](Get-PropertyValue $entry 'cache_path')
        $changeBundle = Read-JsonFile $cachePath

        $id = [string](Get-PropertyValue $changeBundle 'id')
        $change = Get-PropertyValue $changeBundle 'change'
        $rawUpdates = Get-PropertyValue $changeBundle 'updates'
        $rawResolvedUpdaters = Get-PropertyValue $changeBundle 'resolved_updaters'
        if ($null -eq $rawResolvedUpdaters) {
            $rawResolvedUpdaters = [pscustomobject]@{}
        }

        $visibleWarnings = [System.Collections.Generic.List[string]]::new()
        foreach ($warning in @((Get-PropertyValue $changeBundle 'warnings'))) {
            if ($ShouldIncludeUpdates -or (-not [string]$warning.StartsWith('apiUser lookup failed'))) {
                [void]$visibleWarnings.Add([string]$warning)
            }
        }

        $visibleErrors = [System.Collections.Generic.List[string]]::new()
        foreach ($error in @((Get-PropertyValue $changeBundle 'errors'))) {
            if ($ShouldIncludeUpdates -or (-not [string]$error.StartsWith('updates fetch failed'))) {
                [void]$visibleErrors.Add([string]$error)
            }
        }

        $visibleBundleParams = @{
            Id = $id
            Change = $change
            Updates = $rawUpdates
            ResolvedUpdaters = $rawResolvedUpdaters
            Warnings = @($visibleWarnings.ToArray())
            Errors = @($visibleErrors.ToArray())
            Reference = [string](Get-PropertyValue $changeBundle 'reference')
            Kind = [string](Get-PropertyValue $changeBundle 'kind')
            ShouldIncludeUpdates = $ShouldIncludeUpdates
        }
        $visibleBundle = New-ChangeOutput @visibleBundleParams
        [void]$changes.Add([pscustomobject]$visibleBundle)

        if ($null -ne $change) {
            [void]$changeTextParts.Add(("## Change {0}`n{1}" -f $id, (ConvertTo-JsonText $change)).Trim())
        }

        if ($ShouldIncludeUpdates) {
            $updateResults = @(Get-UpdateResults (Get-PropertyValue $visibleBundle 'updates'))
            if ($updateResults.Count -gt 0) {
                [void]$updateTextParts.Add(("## Change {0} Updates`n{1}" -f $id, (ConvertTo-JsonText $updateResults)).Trim())
            } elseif ($null -ne (Get-PropertyValue $visibleBundle 'updates')) {
                [void]$updateTextParts.Add(("## Change {0} Updates`n{1}" -f $id, (ConvertTo-JsonText (Get-PropertyValue $visibleBundle 'updates'))).Trim())
            }
        }

        $qaSourceText = [string](Get-PropertyValue $visibleBundle 'qa_source_text')
        if ($qaSourceText) {
            [void]$qaTextParts.Add($qaSourceText)
        }

        foreach ($warning in @((Get-PropertyValue $visibleBundle 'warnings'))) {
            [void]$warnings.Add(("change {0}: {1}" -f $id, [string]$warning))
        }
        foreach ($error in @((Get-PropertyValue $visibleBundle 'errors'))) {
            [void]$errors.Add(("change {0}: {1}" -f $id, [string]$error))
        }
    }

    return [ordered]@{
        mode_used = $ModeUsed
        session_manifest_path = $ManifestPath
        change_count = $changes.Count
        changes = @($changes)
        combined_change_text = (($changeTextParts -join "`n`n").Trim())
        combined_update_text = (($updateTextParts -join "`n`n").Trim())
        combined_qa_text = (($qaTextParts -join "`n`n").Trim())
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
    }
}

try {
    $resolvedCacheRoot = Get-DefaultCacheRoot
    Ensure-Directory $resolvedCacheRoot
    $manifestPath = Get-ManifestPath $resolvedCacheRoot
    $existingManifest = Read-Manifest $manifestPath

    $mockIndexes = [ordered]@{}
    $apiBaseUri = $null
    $headers = $null
    if ($Mode -eq 'mock') {
        $mockIndexes = Get-MockIndexes (Get-DefaultMockDataPath)
    } else {
        $apiBaseUri = Get-IceApiBaseUri
        $headers = Get-BasicAuthHeaders
    }
    $shouldIncludeUpdates = Test-ShouldFetchUpdates $PromptText ([bool]$IncludeUpdates)

    $requestedRefs = @(Get-RequestedChangeRefs $Ids $PromptText)
    if ($requestedRefs.Count -eq 0 -and $Refresh -and $existingManifest) {
        $requestedRefs = @(Get-ManifestChangeRefs $existingManifest)
    }

    if ($ClearSession -and $requestedRefs.Count -eq 0) {
        $emptyManifest = New-EmptyManifest
        Save-Manifest $manifestPath $emptyManifest
        ([ordered]@{
            mode_used = $Mode
            session_manifest_path = $manifestPath
            change_count = 0
            changes = @()
            combined_change_text = ''
            combined_update_text = ''
            combined_qa_text = ''
            warnings = @()
            errors = @()
        }) | ConvertTo-Json -Depth 100
        exit 0
    }

    if ($requestedRefs.Count -eq 0 -and -not $existingManifest) {
        throw 'No change IDs or URLs were provided and no active session manifest exists.'
    }

    $activeEntries = @(Resolve-ActiveChanges $existingManifest $requestedRefs $resolvedCacheRoot $Mode $MergeMode $shouldIncludeUpdates ([bool]$Refresh) ([bool]$ClearSession) $mockIndexes $apiBaseUri $headers)

    if ($requestedRefs.Count -eq 0 -and -not $ClearSession) {
        $activeEntries = @((Get-PropertyValue $existingManifest 'changes'))
    }

    $manifest = [ordered]@{
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        changes = @($activeEntries)
    }
    Save-Manifest $manifestPath $manifest

    $bundle = Build-OutputBundle $Mode $manifestPath $activeEntries $shouldIncludeUpdates
    $bundle | ConvertTo-Json -Depth 100
} catch {
    Fail $_.Exception.Message
}

