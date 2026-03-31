$CodeReviewMode = "java-expert-diff"
$CodeReviewReviewer = "Senior Java/Spring Reviewer"
$CodeReviewSupportedTargets = @("java-source", "spring-config", "resource-config", "build-config", "logging-config")

function Get-JavaReviewTarget([string]$Path) {
    $normalized = $Path.Replace('\\', '/').ToLowerInvariant()
    $leaf = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($leaf)
    if ($leaf -match '^(logback|log4j)[^/]*\.xml$') { return 'logging-config' }
    if ($leaf -match '^pom\.xml$' -or $leaf -match '^build\.gradle(\.kts)?$') { return 'build-config' }
    if ($leaf -match '^(application|bootstrap)[^/]*\.(yml|yaml|properties)$') { return 'spring-config' }
    if ($extension -eq '.java') { return 'java-source' }
    if ($normalized.StartsWith('src/main/resources/')) {
        if ($extension -in @('.yml', '.yaml', '.properties', '.xml', '.json', '.conf')) { return 'resource-config' }
    }
    return 'unsupported'
}

function Get-ReviewLanguage([string]$ReviewTarget) {
    switch ($ReviewTarget) {
        'java-source' { return 'Java' }
        'spring-config' { return 'Java Ecosystem' }
        'resource-config' { return 'Java Ecosystem' }
        'build-config' { return 'Java Ecosystem' }
        'logging-config' { return 'Java Ecosystem' }
        default { return 'Unknown' }
    }
}

function Get-JavaAnalyzerRegistry {
    return [ordered]@{
        'java-source' = 'Invoke-JavaSourceAnalyzer'
        'spring-config' = 'Invoke-SpringConfigAnalyzer'
        'resource-config' = 'Invoke-ResourceConfigAnalyzer'
        'build-config' = 'Invoke-BuildConfigAnalyzer'
        'logging-config' = 'Invoke-LoggingConfigAnalyzer'
    }
}

function Get-CommonExpertFindings([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    if ($PatchText.ToLowerInvariant().Contains('todo')) {
        $findings += New-CodeFinding 'medium' 'TODO remains in a Java review surface' "$($FileEntry.filename): the diff still contains a TODO in a Java review surface, which suggests the implementation path is not decision-complete for production." 'Resolve the TODO before merge or convert it into a tracked follow-up with explicit owner, scope, and rollout constraints.' @($FileEntry.filename)
    }
    return $findings
}

function Invoke-JavaSourceAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($PatchText -match 'catch\s*\(\s*Exception\b') {
        $findings += New-CodeFinding 'high' 'Broad catch obscures Java failure semantics' "$($FileEntry.filename): catching Exception in the changed Java flow hides the concrete failure mode and makes retry behavior harder to reason about in a Spring service." 'Catch the narrowest expected exception type, preserve the original cause, and let the webhook or transaction boundary decide whether the operation should be retried.' @($FileEntry.filename)
    }
    if (($PatchText -match 'catch\s*\([^)]+\)') -and ($lowered -match 'return\s+null|return\s*;|return\s+optional\.empty\(\)')) {
        $findings += New-CodeFinding 'high' 'Catch block appears to swallow the failure path' "$($FileEntry.filename): the diff suggests the catch path returns control without surfacing the failure, which can silently mark the Java flow as successful when the side effect failed." 'Propagate the failure or map it to an explicit domain result that preserves retry semantics and operational visibility.' @($FileEntry.filename)
    }
    if (($lowered.Contains('.get()')) -and ($lowered.Contains('optional') -or $lowered.Contains('findbyid('))) {
        $findings += New-CodeFinding 'high' 'Optional.get() assumes data presence in the changed path' "$($FileEntry.filename): the diff calls Optional.get() on a path that appears to load data dynamically, so a missing record now turns into a runtime failure instead of an explicit branch." 'Replace Optional.get() with orElseThrow, map, or an explicit empty-path branch that documents the domain expectation.' @($FileEntry.filename)
    }
    if (($lowered.Contains('logger.')) -and ($lowered -match 'token|secret|authorization|password|webhook-secret')) {
        $findings += New-CodeFinding 'high' 'Java logging path appears to expose sensitive request context' "$($FileEntry.filename): the changed log statement appears to emit token, secret, authorization, or password material from the Java request path." 'Remove the sensitive value from logs or replace it with a redacted identifier that still supports supportability and traceability.' @($FileEntry.filename)
    }
    if ($PatchText -match 'private\s+static\s+(final\s+)?(List|Map|Set|HashMap|HashSet|ArrayList)') {
        $findings += New-CodeFinding 'medium' 'Shared mutable state was introduced into the Java class' "$($FileEntry.filename): the diff introduces static mutable collection state, which is easy to misuse under concurrent request handling in a Spring application." 'Move mutable request state out of static fields or wrap it behind a concurrency-safe component with explicit lifecycle and ownership.' @($FileEntry.filename)
    }
    $markerIndex = $lowered.IndexOf('markprocessed(')
    $sideEffectPatterns = @('applyrefund(', 'publish', 'send', 'notify', 'adjust', 'complete', 'dispatch')
    $sideEffectIndex = -1
    foreach ($pattern in $sideEffectPatterns) {
        $candidate = $lowered.IndexOf($pattern)
        if ($candidate -ge 0 -and ($sideEffectIndex -lt 0 -or $candidate -lt $sideEffectIndex)) {
            $sideEffectIndex = $candidate
        }
    }
    if ($markerIndex -ge 0 -and $sideEffectIndex -gt $markerIndex) {
        $findings += New-CodeFinding 'high' 'Idempotency marker is written before the side effect completes' "$($FileEntry.filename): the diff writes the processed marker before the downstream side effect finishes, so a retry can be skipped even if the business action failed after the marker write." 'Persist the idempotency marker only after the side effect commits successfully, or store an explicit in-progress state with compensating retry semantics.' @($FileEntry.filename)
    }
    return $findings
}

function Invoke-SpringConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered.Contains('allow-bean-definition-overriding: true')) {
        $findings += New-CodeFinding 'medium' 'Spring configuration enables bean overriding' "$($FileEntry.filename): the diff enables bean-definition overriding, which can hide wiring mistakes and produce environment-specific startup behavior." 'Keep bean overriding disabled unless there is a documented and tested reason to allow ambiguous wiring in this service.' @($FileEntry.filename)
    }
    if ($lowered -match '(webhook-secret|password|secret|token)\s*:\s*(?!\$\{)(?!enc\()') {
        $findings += New-CodeFinding 'high' 'Spring config introduces a literal secret value' "$($FileEntry.filename): the changed Spring configuration appears to store a secret-like value directly in the file instead of resolving it from the environment or secret manager." 'Replace the literal with an externalized secret reference and document the required environment contract.' @($FileEntry.filename)
    }
    if ($lowered -match 'max-attempts\s*:\s*(1[0-9]|[2-9][0-9]+)') {
        $findings += New-CodeFinding 'medium' 'Retry policy looks aggressive for a Spring service path' "$($FileEntry.filename): the configured retry count is high enough that the same failing operation may now repeat many times before surfacing, amplifying side effects and queue pressure." 'Revisit the retry budget, backoff policy, and idempotency guarantees for this integration path.' @($FileEntry.filename)
    }
    if ($lowered -match 'timeout(-ms)?\s*:\s*0\b') {
        $findings += New-CodeFinding 'high' 'Spring timeout is effectively disabled' "$($FileEntry.filename): the changed config sets a timeout to zero, which usually disables the guardrail and can let callers hang indefinitely under downstream failure." 'Set an explicit timeout that matches the service SLO and downstream retry policy.' @($FileEntry.filename)
    }
    if ($lowered -match 'spring\.security\.enabled\s*:\s*false' -or $lowered -match 'management\.endpoints\.web\.exposure\.include\s*:\s*["'']?\*["'']?') {
        $findings += New-CodeFinding 'high' 'Spring security posture appears to be weakened by configuration' "$($FileEntry.filename): the diff relaxes a security-sensitive Spring setting, which deserves explicit justification and regression coverage before merge." 'Document the operational need, scope the exposure as narrowly as possible, and add a regression test that proves the intended access boundary.' @($FileEntry.filename)
    }
    return $findings
}

function Invoke-ResourceConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match '(webhook-secret|password|secret|token)\s*[:=]\s*(?!\$\{)(?!enc\()') {
        $findings += New-CodeFinding 'high' 'Runtime resource config appears to inline a secret' "$($FileEntry.filename): the resource file includes a literal secret-like value, which turns a deploy-time secret into repo-tracked configuration." 'Externalize the secret into environment-backed configuration and keep only the property key in source control.' @($FileEntry.filename)
    }
    if ($lowered -match 'timeout(-ms)?\s*[:=]\s*0\b' -or $lowered -match 'max-attempts\s*[:=]\s*(1[0-9]|[2-9][0-9]+)') {
        $findings += New-CodeFinding 'medium' 'Runtime resource config changes retry or timeout behavior materially' "$($FileEntry.filename): the resource-level configuration changes timeout or retry semantics enough to warrant an integration test and rollout note." 'Add a boot-time or integration test that proves the new property values produce the intended runtime behavior.' @($FileEntry.filename)
    }
    return $findings
}

function Invoke-BuildConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match 'maven\.test\.skip>\s*true<' -or $lowered -match '<skiptests>\s*true<' -or $lowered -match 'skiptests\s*=\s*true' -or $lowered -match 'test\s*\{[^}]*enabled\s*=\s*false') {
        $findings += New-CodeFinding 'high' 'Build configuration disables or skips the Java test phase' "$($FileEntry.filename): the diff disables tests in the build path, which removes the most direct safety net for the changed Java service behavior." 'Keep the test phase enabled and solve the underlying flake or environment problem explicitly instead of masking it in build configuration.' @($FileEntry.filename)
    }
    if ($lowered -match '<java\.version>' -or $lowered -match 'sourcecompatibility' -or $lowered -match 'targetcompatibility') {
        $findings += New-CodeFinding 'medium' 'Java runtime or compiler level changed in the build' "$($FileEntry.filename): the diff changes the declared Java level, which can alter bytecode compatibility, container expectations, and library support assumptions." 'Confirm runtime image compatibility, dependency support, and CI coverage for the new Java level before merge.' @($FileEntry.filename)
    }
    if (($lowered.Contains('spring-boot')) -and ($lowered.Contains('version') -or $lowered.Contains('dependencymanagement'))) {
        $findings += New-CodeFinding 'medium' 'Spring dependency train changed in build configuration' "$($FileEntry.filename): the diff alters Spring-related dependency management, which can shift transitive behavior beyond the touched code path." 'Document the dependency change, verify startup behavior, and add focused smoke coverage for the affected Spring slice.' @($FileEntry.filename)
    }
    return $findings
}

function Invoke-LoggingConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match '%x\{(token|authorization|password|secret)\}' -or $lowered -match '%mdc\{(token|authorization|password|secret)\}' -or $lowered -match 'authorization|password|secret') {
        $findings += New-CodeFinding 'high' 'Logging configuration emits sensitive request context' "$($FileEntry.filename): the logging pattern appears to include token, authorization, password, or secret material in the emitted event payload." 'Remove the sensitive field from the logging pattern or mask it before it reaches the appender.' @($FileEntry.filename)
    }
    if ($lowered -match '<root\s+level\s*=\s*"debug"' -or $lowered -match 'root\s+level\s*=\s*debug') {
        $findings += New-CodeFinding 'medium' 'Root logger was raised to DEBUG' "$($FileEntry.filename): the root logging level is now DEBUG, which can flood production logs and expose operational or request context that was previously suppressed." 'Keep DEBUG scoped to the minimal package set needed for diagnosis and preserve a production-safe root logger level.' @($FileEntry.filename)
    }
    return $findings
}

function Get-JavaExpertTestSuggestions([string[]]$ReviewTargets, [object[]]$CodeFiles, [object[]]$TestFiles, [string[]]$RiskyPaths) {
    $items = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    function Add-Item([string]$Value) {
        if ($Value -and $seen.Add($Value)) { [void]$items.Add($Value) }
    }
    if ($CodeFiles.Count -gt 0 -and $TestFiles.Count -eq 0) { Add-Item 'Add targeted regression tests for the changed production paths because no Java test files changed.' }
    if ($ReviewTargets -contains 'java-source') { Add-Item 'Add Java regression coverage for exception handling, retry semantics, and state transitions touched in the diff.' }
    if (@((@('spring-config', 'resource-config') | Where-Object { $ReviewTargets -contains $_ })).Count -gt 0) { Add-Item 'Add a Spring Boot integration test that boots the changed configuration and verifies property binding, retry, timeout, and security behavior.' }
    if ($ReviewTargets -contains 'build-config') { Add-Item 'Add build verification that exercises the affected Maven or Gradle test and packaging configuration instead of trusting the file diff alone.' }
    if ($ReviewTargets -contains 'logging-config') { Add-Item 'Add a logging regression test or snapshot proving sensitive fields stay masked and the intended logger level is preserved.' }
    if (@(@($RiskyPaths | Where-Object { $_ -match 'payment|billing' })).Count -gt 0) { Add-Item 'Add an integration test covering duplicate events, retries, idempotency, and downstream side effects for the payment flow.' }
    if (@(@($RiskyPaths | Where-Object { $_ -match 'migration|sql|schema' })).Count -gt 0) { Add-Item 'Add a migration compatibility test covering existing rows, rollout, rollback, and read-write compatibility.' }
    if (@(@($RiskyPaths | Where-Object { $_ -match 'auth|permission|security' })).Count -gt 0) { Add-Item 'Add authorization and negative-path tests proving unsafe callers are rejected under the new Java and Spring configuration path.' }
    if ($items.Count -eq 0 -and $CodeFiles.Count -gt 0) { Add-Item 'Add focused Java unit coverage plus one end-to-end regression around the primary business flow touched in the PR.' }
    return @($items | Select-Object -First 8)
}

