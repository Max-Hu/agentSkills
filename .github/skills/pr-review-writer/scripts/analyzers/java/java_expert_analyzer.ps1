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

function New-JavaCodeFinding(
    [string]$Severity,
    [string]$Title,
    [string]$Details,
    [string]$SuggestedFix,
    [hashtable]$FileEntry,
    [string]$PatchText,
    [string]$MatchReason,
    [string[]]$MatchPatterns,
    [string]$ReferenceFix,
    [string]$ReferenceTest
) {
    return New-CodeFinding $Severity $Title $Details $SuggestedFix @($FileEntry.filename) $FileEntry $PatchText $MatchReason $MatchPatterns $ReferenceFix $ReferenceTest
}

function Get-CommonExpertFindings([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    if ($PatchText.ToLowerInvariant().Contains('todo')) {
        $findings += New-JavaCodeFinding 'medium' 'TODO remains in a Java review surface' "$($FileEntry.filename): the diff still contains a TODO in a Java review surface, which suggests the implementation path is not decision-complete for production." 'Resolve the TODO before merge or convert it into a tracked follow-up with explicit owner, scope, and rollout constraints.' $FileEntry $PatchText 'Matched a TODO marker inside the reviewed Java diff.' @('todo') '/* Reference only: replace the TODO with the concrete production-safe implementation or remove it before merge. */' 'Add a regression test that proves the deferred TODO path is either implemented or intentionally unreachable in production.'
    }
    return $findings
}

function Invoke-JavaSourceAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($PatchText -match 'catch\s*\(\s*Exception\b') {
        $findings += New-JavaCodeFinding 'high' 'Broad catch obscures Java failure semantics' "$($FileEntry.filename): catching Exception in the changed Java flow hides the concrete failure mode and makes retry behavior harder to reason about in a Spring service." 'Catch the narrowest expected exception type, preserve the original cause, and let the webhook or transaction boundary decide whether the operation should be retried.' $FileEntry $PatchText 'Matched a broad catch on the changed Java path.' @('catch\s*\(\s*Exception\b') @'
try {
    performChangedOperation();
} catch (SpecificDomainException ex) {
    throw ex;
}
'@ 'Add a test proving the specific downstream exception is surfaced instead of being hidden behind a catch-all block.'
    }
    if (($PatchText -match 'catch\s*\([^)]+\)') -and ($lowered -match 'return\s+null|return\s*;|return\s+optional\.empty\(\)')) {
        $findings += New-JavaCodeFinding 'high' 'Catch block appears to swallow the failure path' "$($FileEntry.filename): the diff suggests the catch path returns control without surfacing the failure, which can silently mark the Java flow as successful when the side effect failed." 'Propagate the failure or map it to an explicit domain result that preserves retry semantics and operational visibility.' $FileEntry $PatchText 'Matched a catch block that returns a success-like value or exits silently.' @('catch\s*\([^)]+\)', 'return\s+null', 'return\s*;', 'return\s+optional\.empty\(\)') @'
try {
    ledgerClient.applyRefund(refundRequest);
} catch (LedgerClientException ex) {
    throw ex;
}
'@ 'Add a test proving a downstream refund failure is visible to callers and does not silently return null or an empty success value.'
    }
    if (($lowered.Contains('.get()')) -and ($lowered.Contains('optional') -or $lowered.Contains('findbyid('))) {
        $findings += New-JavaCodeFinding 'high' 'Optional.get() assumes data presence in the changed path' "$($FileEntry.filename): the diff calls Optional.get() on a path that appears to load data dynamically, so a missing record now turns into a runtime failure instead of an explicit branch." 'Replace Optional.get() with orElseThrow, map, or an explicit empty-path branch that documents the domain expectation.' $FileEntry $PatchText 'Matched Optional.get() on a lookup path that appears to load data dynamically.' @('\.get\(\)', 'findbyid\(') @'
var refund = refundRepository.findById(refundId)
    .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
return ResponseEntity.ok(refund);
'@ 'Add a controller test proving a missing refundId returns the expected not-found behavior instead of a runtime failure.'
    }
    if (($lowered.Contains('logger.')) -and ($lowered -match 'token|secret|authorization|password|webhook-secret')) {
        $findings += New-JavaCodeFinding 'high' 'Java logging path appears to expose sensitive request context' "$($FileEntry.filename): the changed log statement appears to emit token, secret, authorization, or password material from the Java request path." 'Remove the sensitive value from logs or replace it with a redacted identifier that still supports supportability and traceability.' $FileEntry $PatchText 'Matched a Java log statement that appears to include token or secret material.' @('logger\.', 'token', 'secret', 'authorization', 'password', 'webhook-secret') @'
logger.info("processed webhook eventId={}", eventId);
'@ 'Add a log assertion proving token, authorization, or secret values are redacted or absent from emitted messages.'
    }
    if ($PatchText -match 'private\s+static\s+(final\s+)?(List|Map|Set|HashMap|HashSet|ArrayList)') {
        $findings += New-JavaCodeFinding 'medium' 'Shared mutable state was introduced into the Java class' "$($FileEntry.filename): the diff introduces static mutable collection state, which is easy to misuse under concurrent request handling in a Spring application." 'Move mutable request state out of static fields or wrap it behind a concurrency-safe component with explicit lifecycle and ownership.' $FileEntry $PatchText 'Matched a static mutable collection introduced on the changed Java path.' @('private\s+static\s+(final\s+)?(List|Map|Set|HashMap|HashSet|ArrayList)') @'
private final ConcurrentMap<String, ProcessingState> processingStateByEventId = new ConcurrentHashMap<>();
'@ 'Add concurrency-focused coverage or remove the shared mutable state from the request path before merge.'
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
        $findings += New-JavaCodeFinding 'high' 'Idempotency marker is written before the side effect completes' "$($FileEntry.filename): the diff writes the processed marker before the downstream side effect finishes, so a retry can be skipped even if the business action failed after the marker write." 'Persist the idempotency marker only after the side effect commits successfully, or store an explicit in-progress state with compensating retry semantics.' $FileEntry $PatchText 'Matched markProcessed() before a downstream side effect on the changed Java path.' @('markprocessed\(', 'applyrefund\(', 'publish', 'send', 'notify', 'adjust', 'complete', 'dispatch') @'
ledgerClient.applyRefund(refundRequest);
repository.markProcessed(eventId);
'@ 'Add a test proving a failed downstream applyRefund does not mark the event as processed and that a retry can still recover.'
    }
    return $findings
}

function Invoke-SpringConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered.Contains('allow-bean-definition-overriding: true')) {
        $findings += New-JavaCodeFinding 'medium' 'Spring configuration enables bean overriding' "$($FileEntry.filename): the diff enables bean-definition overriding, which can hide wiring mistakes and produce environment-specific startup behavior." 'Keep bean overriding disabled unless there is a documented and tested reason to allow ambiguous wiring in this service.' $FileEntry $PatchText 'Matched bean-definition overriding enabled in the changed Spring configuration.' @('allow-bean-definition-overriding:\s*true') @'
spring:
  main:
    allow-bean-definition-overriding: false
'@ 'Add a boot test that fails if duplicate bean definitions would otherwise be silently overridden.'
    }
    if ($lowered -match '(webhook-secret|password|secret|token)\s*:\s*(?!\$\{)(?!enc\()') {
        $findings += New-JavaCodeFinding 'high' 'Spring config introduces a literal secret value' "$($FileEntry.filename): the changed Spring configuration appears to store a secret-like value directly in the file instead of resolving it from the environment or secret manager." 'Replace the literal with an externalized secret reference and document the required environment contract.' $FileEntry $PatchText 'Matched a literal secret-like value in Spring configuration.' @('(webhook-secret|password|secret|token)\s*:\s*(?!\$\{)(?!enc\()') @'
payments:
  refund:
    webhook-secret: ${PAYMENTS_REFUND_WEBHOOK_SECRET}
'@ 'Add a boot-time test proving the secret is loaded from environment-backed configuration and not committed as a literal.'
    }
    if ($lowered -match 'max-attempts\s*:\s*(1[0-9]|[2-9][0-9]+)') {
        $findings += New-JavaCodeFinding 'medium' 'Retry policy looks aggressive for a Spring service path' "$($FileEntry.filename): the configured retry count is high enough that the same failing operation may now repeat many times before surfacing, amplifying side effects and queue pressure." 'Revisit the retry budget, backoff policy, and idempotency guarantees for this integration path.' $FileEntry $PatchText 'Matched a high max-attempts retry budget in Spring configuration.' @('max-attempts\s*:\s*(1[0-9]|[2-9][0-9]+)') @'
payments:
  refund:
    retry:
      max-attempts: 3
'@ 'Add a property-binding or integration test that asserts the reduced retry budget and the intended backoff contract.'
    }
    if ($lowered -match 'timeout(-ms)?\s*:\s*0\b') {
        $findings += New-JavaCodeFinding 'high' 'Spring timeout is effectively disabled' "$($FileEntry.filename): the changed config sets a timeout to zero, which usually disables the guardrail and can let callers hang indefinitely under downstream failure." 'Set an explicit timeout that matches the service SLO and downstream retry policy.' $FileEntry $PatchText 'Matched a zero timeout value in Spring configuration.' @('timeout(-ms)?\s*:\s*0\b') @'
payments:
  refund:
    timeout-ms: 2000
'@ 'Add an integration test proving downstream calls time out within the configured budget.'
    }
    if ($lowered -match 'spring\.security\.enabled\s*:\s*false' -or $lowered -match 'management\.endpoints\.web\.exposure\.include\s*:\s*["'']?\*["'']?') {
        $findings += New-JavaCodeFinding 'high' 'Spring security posture appears to be weakened by configuration' "$($FileEntry.filename): the diff relaxes a security-sensitive Spring setting, which deserves explicit justification and regression coverage before merge." 'Document the operational need, scope the exposure as narrowly as possible, and add a regression test that proves the intended access boundary.' $FileEntry $PatchText 'Matched a security-sensitive Spring configuration setting being widened.' @('spring\.security\.enabled\s*:\s*false', 'management\.endpoints\.web\.exposure\.include\s*:\s*["'']?\*["'']?') @'
management:
  endpoints:
    web:
      exposure:
        include: "health,info"
'@ 'Add an authorization regression test proving only the intended endpoints remain exposed under the new configuration.'
    }
    return $findings
}

function Invoke-ResourceConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match '(webhook-secret|password|secret|token)\s*[:=]\s*(?!\$\{)(?!enc\()') {
        $findings += New-JavaCodeFinding 'high' 'Runtime resource config appears to inline a secret' "$($FileEntry.filename): the resource file includes a literal secret-like value, which turns a deploy-time secret into repo-tracked configuration." 'Externalize the secret into environment-backed configuration and keep only the property key in source control.' $FileEntry $PatchText 'Matched a literal secret-like value in a runtime resource file.' @('(webhook-secret|password|secret|token)\s*[:=]\s*(?!\$\{)(?!enc\()') @'
webhook-secret=${PAYMENTS_REFUND_WEBHOOK_SECRET}
'@ 'Add a boot-time test proving the runtime resource resolves the secret from environment-backed configuration only.'
    }
    if ($lowered -match 'timeout(-ms)?\s*[:=]\s*0\b' -or $lowered -match 'max-attempts\s*[:=]\s*(1[0-9]|[2-9][0-9]+)') {
        $findings += New-JavaCodeFinding 'medium' 'Runtime resource config changes retry or timeout behavior materially' "$($FileEntry.filename): the resource-level configuration changes timeout or retry semantics enough to warrant an integration test and rollout note." 'Add a boot-time or integration test that proves the new property values produce the intended runtime behavior.' $FileEntry $PatchText 'Matched a timeout or retry budget change in a runtime resource file.' @('timeout(-ms)?\s*[:=]\s*0\b', 'max-attempts\s*[:=]\s*(1[0-9]|[2-9][0-9]+)') @'
retry.max-attempts=3
timeout-ms=2000
'@ 'Add a property-binding or boot-time test proving the changed retry and timeout values produce the intended runtime behavior.'
    }
    return $findings
}

function Invoke-BuildConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match 'maven\.test\.skip>\s*true<' -or $lowered -match '<skiptests>\s*true<' -or $lowered -match 'skiptests\s*=\s*true' -or $lowered -match 'test\s*\{[^}]*enabled\s*=\s*false') {
        $findings += New-JavaCodeFinding 'high' 'Build configuration disables or skips the Java test phase' "$($FileEntry.filename): the diff disables tests in the build path, which removes the most direct safety net for the changed Java service behavior." 'Keep the test phase enabled and solve the underlying flake or environment problem explicitly instead of masking it in build configuration.' $FileEntry $PatchText 'Matched a build setting that disables the Java test phase.' @('maven\.test\.skip>\s*true<', '<skiptests>\s*true<', 'skiptests\s*=\s*true', 'test\s*\{[^}]*enabled\s*=\s*false') @'
<properties>
    <maven.test.skip>false</maven.test.skip>
</properties>
'@ 'Add CI or build coverage proving the changed Maven or Gradle path still runs tests before merge.'
    }
    if ($lowered -match '<java\.version>' -or $lowered -match 'sourcecompatibility' -or $lowered -match 'targetcompatibility') {
        $findings += New-JavaCodeFinding 'medium' 'Java runtime or compiler level changed in the build' "$($FileEntry.filename): the diff changes the declared Java level, which can alter bytecode compatibility, container expectations, and library support assumptions." 'Confirm runtime image compatibility, dependency support, and CI coverage for the new Java level before merge.' $FileEntry $PatchText 'Matched a Java runtime or compiler level change in build configuration.' @('<java\.version>', 'sourcecompatibility', 'targetcompatibility') @'
<properties>
    <java.version>21</java.version>
</properties>
'@ 'Add CI coverage on the declared Java runtime image and verify the deployment runtime matches before merge.'
    }
    if (($lowered.Contains('spring-boot')) -and ($lowered.Contains('version') -or $lowered.Contains('dependencymanagement'))) {
        $findings += New-JavaCodeFinding 'medium' 'Spring dependency train changed in build configuration' "$($FileEntry.filename): the diff alters Spring-related dependency management, which can shift transitive behavior beyond the touched code path." 'Document the dependency change, verify startup behavior, and add focused smoke coverage for the affected Spring slice.' $FileEntry $PatchText 'Matched a Spring-related dependency version change in build configuration.' @('spring-boot', 'version', 'dependencymanagement') @'
<properties>
    <spring-boot.version>3.3.1</spring-boot.version>
</properties>
'@ 'Add a startup smoke test covering the Spring slice touched by this PR under the updated dependency train.'
    }
    return $findings
}

function Invoke-LoggingConfigAnalyzer([hashtable]$FileEntry, [string]$PatchText) {
    $findings = @()
    $lowered = $PatchText.ToLowerInvariant()
    if ($lowered -match '%x\{(token|authorization|password|secret)\}' -or $lowered -match '%mdc\{(token|authorization|password|secret)\}' -or $lowered -match 'authorization|password|secret') {
        $findings += New-JavaCodeFinding 'high' 'Logging configuration emits sensitive request context' "$($FileEntry.filename): the logging pattern appears to include token, authorization, password, or secret material in the emitted event payload." 'Remove the sensitive field from the logging pattern or mask it before it reaches the appender.' $FileEntry $PatchText 'Matched token or authorization fields in the logging pattern.' @('%x\{(token|authorization|password|secret)\}', '%mdc\{(token|authorization|password|secret)\}', 'authorization', 'password', 'secret') @'
<pattern>%d %-5level %logger - eventId=%X{eventId} %msg%n</pattern>
'@ 'Add a logging regression test proving MDC token and authorization fields are masked or absent from emitted log lines.'
    }
    if ($lowered -match '<root\s+level\s*=\s*"debug"' -or $lowered -match 'root\s+level\s*=\s*debug') {
        $findings += New-JavaCodeFinding 'medium' 'Root logger was raised to DEBUG' "$($FileEntry.filename): the root logging level is now DEBUG, which can flood production logs and expose operational or request context that was previously suppressed." 'Keep DEBUG scoped to the minimal package set needed for diagnosis and preserve a production-safe root logger level.' $FileEntry $PatchText 'Matched the root logger level being raised to DEBUG.' @('<root\s+level\s*=\s*"debug"', 'root\s+level\s*=\s*debug') @'
<root level="INFO">
'@ 'Add a logging snapshot test proving the production-safe root level remains in place after the change.'
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

