param(
    [string]$InputPath,
    [string]$DraftPath,
    [ValidateSet("markdown", "json")]
    [string]$OutputFormat = "markdown",
    [string]$ModeUsed,
    [string]$PromptText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SeverityOrder = @{ critical = 0; high = 1; medium = 2; low = 3 }
$CategoryOrder = @{ "Jira Alignment" = 0; "Implementation Risk" = 1; "Code Quality" = 2; "Test Gap" = 3; "Reviewer Concern" = 4 }
$Stopwords = @("a","an","and","are","for","from","the","this","that","with","into","when","during","still","does","not")
$DocExtensions = @(".md", ".txt", ".rst", ".adoc")
$HighRiskPathHints = @("migration", "schema", "payment", "billing", "auth", "permission", "security", "terraform", "k8s", "helm", "config", "sql")
$JavaExpertAnalyzerPath = Join-Path $PSScriptRoot 'analyzers\java\java_expert_analyzer.ps1'
if (-not (Test-Path $JavaExpertAnalyzerPath)) { throw "Missing Java expert analyzer at $JavaExpertAnalyzerPath" }
. $JavaExpertAnalyzerPath
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

function Get-ValueOrDefault([object]$Value, [object]$Default) {
    if ($null -eq $Value) { return $Default }
    return $Value
}

function Get-Json([string]$Path) {
    return ConvertFrom-JsonCompat (Get-Content -Raw -Encoding UTF8 $Path)
}

function Write-TextFile([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Set-Content -Encoding UTF8 -Path $Path -Value $Content
    return (Resolve-Path $Path).Path
}

function ConvertFrom-Adf([object]$Node) {
    if ($null -eq $Node) { return "" }
    if ($Node -is [string]) { return [string]$Node }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [System.Collections.IDictionary])) {
        $parts = foreach ($item in $Node) {
            $text = ConvertFrom-Adf $item
            if ($text) { $text }
        }
        return ($parts -join "`n").Trim()
    }
    if ($Node.type -eq "text") { return [string]$Node.text }
    $content = @()
    foreach ($item in @($Node.content)) {
        $text = ConvertFrom-Adf $item
        if ($text) { $content += $text }
    }
    $joined = ($content -join "`n").Trim()
    if ($Node.type -in @("paragraph", "heading", "listItem")) { return $joined }
    if ($Node.type -in @("bulletList", "orderedList")) {
        return ((($joined -split "`r?`n") | Where-Object { $_ }) | ForEach-Object { "- $_" }) -join "`n"
    }
    return $joined
}

function Get-JiraIssueSummary([object]$Issue) {
    $fields = $Issue.fields
    $descriptionText = ConvertFrom-Adf $fields.description
    $commentEntries = @($Issue.comments)
    if ($commentEntries.Count -eq 0 -and $fields.comment.comments) {
        $commentEntries = @($fields.comment.comments)
    }
    $commentExcerpts = @()
    foreach ($comment in $commentEntries | Select-Object -First 6) {
        $author = if ($comment.PSObject.Properties.Name -contains 'user' -and $comment.user.PSObject.Properties.Name -contains 'login') { $comment.user.login } elseif ($comment.PSObject.Properties.Name -contains 'author' -and $comment.author.PSObject.Properties.Name -contains 'displayName') { $comment.author.displayName } else { 'unknown' }
        $body = [regex]::Replace((ConvertFrom-Adf $comment.body), '\s+', ' ').Trim()
        if ($body) {
            if ($body.Length -gt 160) { $body = $body.Substring(0, 157).TrimEnd() + '...' }
            $commentExcerpts += "${author}: $body"
        }
    }
    return [ordered]@{
        key = if ($Issue.key) { $Issue.key } else { 'UNKNOWN' }
        title = if ($fields.summary) { $fields.summary } else { 'No summary' }
        status = if ($fields.status.name) { $fields.status.name } else { 'Unknown' }
        priority = if ($fields.priority.name) { $fields.priority.name } else { 'Unknown' }
        assignee = if ($fields.assignee.displayName) { $fields.assignee.displayName } else { 'Unassigned' }
        description_text = $descriptionText
        comment_excerpts = $commentExcerpts
    }
}

function Tokenize([string]$Text) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($match in [regex]::Matches(([string](Get-ValueOrDefault $Text '')).ToLowerInvariant(), '[a-z0-9]+')) {
        $token = $match.Value
        if ($token.Length -gt 2 -and -not ($Stopwords -contains $token) -and -not ($token -match '^\d+$')) {
            [void]$set.Add($token)
        }
    }
    return $set
}

function Test-IsTestFile([string]$Path) {
    $normalized = $Path.Replace('\\', '/')
    return [bool]([regex]::IsMatch($normalized, '(^|/)(tests?|__tests__|src/test)/|(_test|_spec)\.|(\.test\.|\.spec\.)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function Test-IsDocFile([string]$Path) {
    $normalized = $Path.Replace('\\', '/').ToLowerInvariant()
    return ($DocExtensions -contains ([IO.Path]::GetExtension($Path).ToLowerInvariant())) -or $normalized.StartsWith('docs/') -or $normalized.StartsWith('doc/')
}

function Get-PatchExcerpt([string]$Patch) {
    if ([string]::IsNullOrWhiteSpace($Patch)) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Patch -split "`r?`n")) {
        if ($line.StartsWith('+++') -or $line.StartsWith('---')) { continue }
        if ($line.StartsWith('@@') -or $line.StartsWith('+') -or $line.StartsWith('-')) {
            $lines.Add($line)
        }
        if ($lines.Count -ge 20) { break }
    }
    $excerpt = ($lines -join "`n").Trim()
    if ($excerpt.Length -gt 1800) { $excerpt = $excerpt.Substring(0, 1797).TrimEnd() + '...' }
    return $excerpt
}

function Get-CommentExcerpts([object[]]$Comments, [int]$Limit) {
    $items = @()
    foreach ($comment in @($Comments) | Select-Object -First $Limit) {
        $author = if ($comment.PSObject.Properties.Name -contains 'user' -and $comment.user.PSObject.Properties.Name -contains 'login') { $comment.user.login } elseif ($comment.PSObject.Properties.Name -contains 'author' -and $comment.author.PSObject.Properties.Name -contains 'displayName') { $comment.author.displayName } else { 'unknown' }
        $body = [regex]::Replace(([string]$comment.body), '\s+', ' ').Trim()
        if ($body) {
            if ($body.Length -gt 160) { $body = $body.Substring(0, 157).TrimEnd() + '...' }
            $items += "${author}: $body"
        }
    }
    return $items
}

function New-Finding([string]$Severity, [string]$Category, [string]$Title, [string]$Details, [string]$SuggestedFix, [object[]]$EvidenceRefs) {
    return [ordered]@{
        severity = $Severity
        category = $Category
        title = $Title
        summary = $Title
        details = $Details
        suggested_fix = $SuggestedFix
        evidence_refs = $EvidenceRefs
    }
}

function New-CodeFinding([string]$Severity, [string]$Title, [string]$Details, [string]$SuggestedFix, [object[]]$EvidenceRefs) {
    return New-Finding $Severity 'Code Quality' $Title $Details $SuggestedFix $EvidenceRefs
}
function Sort-Findings([object[]]$Findings) {
    return @($Findings | Sort-Object @{Expression={ $SeverityOrder[$_.severity] }}, @{Expression={ if ($CategoryOrder.ContainsKey($_.category)) { $CategoryOrder[$_.category] } else { 99 } }}, @{Expression={ $_.title }})
}
function Get-TestSuggestions([string[]]$ReviewTargets, [object[]]$CodeFiles, [object[]]$TestFiles, [string[]]$RiskyPaths) {
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

function Get-DiffEvidence([object[]]$Files) {
    $evidenceFiles = @()
    $codeFiles = @()
    $testFiles = @()
    $docFiles = @()
    $patchFiles = @()
    $codeFindingObjects = @()
    $languages = [System.Collections.Generic.HashSet[string]]::new()
    $reviewedTargets = [System.Collections.Generic.HashSet[string]]::new()
    $supportedFiles = [System.Collections.Generic.List[string]]::new()
    $metadataOnlyFiles = [System.Collections.Generic.List[string]]::new()
    $registry = Get-JavaAnalyzerRegistry
    foreach ($item in @($Files)) {
        $filename = [string]$item.filename
        $patchText = if ($item.PSObject.Properties.Name -contains 'patch') { [string]$item.patch } else { '' }
        $reviewTarget = Get-JavaReviewTarget $filename
        $language = Get-ReviewLanguage $reviewTarget
        if ($language -ne 'Unknown') { [void]$languages.Add($language) }
        $entry = [ordered]@{
            filename = $filename
            status = if ($item.status) { $item.status } else { 'modified' }
            additions = [int](Get-ValueOrDefault $item.additions 0)
            deletions = [int](Get-ValueOrDefault $item.deletions 0)
            language = $language
            review_target = $reviewTarget
            is_supported_target = ($reviewTarget -ne 'unsupported')
            is_test = (Test-IsTestFile $filename)
            is_doc = (Test-IsDocFile $filename)
            has_patch = -not [string]::IsNullOrWhiteSpace($patchText)
            patch_excerpt = Get-PatchExcerpt $patchText
        }
        $evidenceFiles += $entry
        if ($entry.is_test) { $testFiles += $entry }
        elseif ($entry.is_doc) { $docFiles += $entry }
        else { $codeFiles += $entry }
        if ($entry.has_patch) { $patchFiles += $entry }
        if ($entry.is_supported_target) {
            [void]$reviewedTargets.Add($reviewTarget)
            [void]$supportedFiles.Add($filename)
        } elseif (-not $entry.is_doc -and -not $entry.is_test) {
            [void]$metadataOnlyFiles.Add($filename)
        }
        if ($entry.has_patch -and $entry.is_supported_target) {
            $codeFindingObjects += Get-CommonExpertFindings $entry $patchText
            if ($registry.Contains($reviewTarget)) {
                $codeFindingObjects += & $registry[$reviewTarget] $entry $patchText
            }
        }
    }
    $languageList = @($languages | Sort-Object)
    $reviewedTargetList = @($reviewedTargets | Sort-Object)
    $codeEvidence = @(
        "$CodeReviewReviewer ran diff-based review without AST or compiler support.",
        "Current code review mode: $CodeReviewMode.",
        "Supported Java review targets: $($CodeReviewSupportedTargets -join ', ')."
    )
    if ($supportedFiles.Count -gt 0) {
        $codeEvidence += "Java ecosystem files eligible for expert review: $((@($supportedFiles | Select-Object -First 6)) -join ', ')."
    } else {
        $codeEvidence += 'No Java ecosystem files were eligible for expert diff review in this change set.'
    }
    if ($metadataOnlyFiles.Count -gt 0) {
        $codeEvidence += "Files outside the Java expert boundary were treated as metadata-only: $((@($metadataOnlyFiles | Select-Object -First 5)) -join ', ')."
    }
    if ($patchFiles.Count -gt 0) {
        $codeEvidence += "Inline patch excerpts are available for $($patchFiles.Count) file(s): $((@($patchFiles | Select-Object -First 4 | ForEach-Object { $_.filename })) -join ', ')."
    } else {
        $codeEvidence += 'No inline patch excerpt was returned by GitHub for code-level inspection.'
    }
    if ($codeFiles.Count -gt 0) { $codeEvidence += "Changed production files: $((@($codeFiles | Select-Object -First 5 | ForEach-Object { $_.filename })) -join ', ')." }
    if ($testFiles.Count -gt 0) { $codeEvidence += "Changed test files: $((@($testFiles | Select-Object -First 4 | ForEach-Object { $_.filename })) -join ', ')." }
    if ($docFiles.Count -gt 0) { $codeEvidence += "Changed documentation files: $((@($docFiles | Select-Object -First 3 | ForEach-Object { $_.filename })) -join ', ')." }
    $positives = @()
    if ($testFiles.Count -gt 0) { $positives += "Test files changed: $((@($testFiles | Select-Object -First 3 | ForEach-Object { $_.filename })) -join ', ')." }
    if ($docFiles.Count -gt 0) { $positives += "Documentation or runbook updates present: $((@($docFiles | Select-Object -First 2 | ForEach-Object { $_.filename })) -join ', ')." }
    if ($supportedFiles.Count -gt 0) { $positives += "Java expert review covered $($supportedFiles.Count) Java ecosystem file(s)." }
    $questions = @()
    foreach ($entry in @($patchFiles | Where-Object { $_.is_supported_target } | Select-Object -First 3)) {
        $questions += "Which runtime behavior changed in $($entry.filename), and which Java or Spring regression test proves the new contract?"
    }
    return [ordered]@{
        languages = $languageList
        reviewed_targets = $reviewedTargetList
        supported_file_count = $supportedFiles.Count
        files = $evidenceFiles
        code_files = $codeFiles
        test_files = $testFiles
        doc_files = $docFiles
        patch_files = $patchFiles
        code_evidence = $codeEvidence
        code_finding_objects = $codeFindingObjects
        code_findings = @($codeFindingObjects | ForEach-Object { $_.details })
        positives = $positives
        questions = $questions
    }
}

function Get-EvidenceSources([string]$ReportPrUrl, [object]$Pull, [object[]]$JiraIssues, [object[]]$Commits, [object[]]$IssueComments, [object[]]$ReviewComments, [hashtable]$DiffEvidence) {
    return [ordered]@{
        pr = [ordered]@{
            url = $ReportPrUrl
            title = if ($Pull.title) { $Pull.title } else { 'Unknown PR' }
            author = if ($Pull.PSObject.Properties.Name -contains 'user' -and $Pull.user.PSObject.Properties.Name -contains 'login') { $Pull.user.login } else { 'unknown' }
            head_ref = if ($Pull.head.ref) { $Pull.head.ref } else { '' }
            base_ref = if ($Pull.base.ref) { $Pull.base.ref } else { '' }
            changed_files = if ($DiffEvidence.files.Count -gt 0) { $DiffEvidence.files.Count } else { [int](Get-ValueOrDefault $Pull.changed_files 0) }
            churn = [int](Get-ValueOrDefault $Pull.additions 0) + [int](Get-ValueOrDefault $Pull.deletions 0)
        }
        jira = @($JiraIssues | ForEach-Object {
            [ordered]@{
                key = $_.key
                title = $_.title
                status = $_.status
                priority = $_.priority
                assignee = $_.assignee
                description_available = [bool]$_.description_text
                comment_count = @($_.comment_excerpts).Count
            }
        })
        commits = @($Commits | Select-Object -First 10 | ForEach-Object { $_.commit.message })
        comments = [ordered]@{
            issue_comments = Get-CommentExcerpts $IssueComments 6
            review_comments = Get-CommentExcerpts $ReviewComments 6
        }
        files = @($DiffEvidence.files | Select-Object -First 20 | ForEach-Object {
            [ordered]@{
                filename = $_.filename
                language = $_.language
                review_target = $_.review_target
                is_supported_target = $_.is_supported_target
                is_test = $_.is_test
                is_doc = $_.is_doc
                has_patch = $_.has_patch
            }
        })
    }
}
function Build-StructuredFindings([string[]]$JiraKeys, [string[]]$AlignmentFindings, [string[]]$RiskFindings, [object[]]$CodeFindingObjects, [string[]]$TestFindings, [string[]]$IssueCommentExcerpts, [string[]]$ReviewCommentExcerpts) {
    $findings = @()
    foreach ($message in $AlignmentFindings) {
        if ($message.StartsWith('No obvious')) { continue }
        if ($message -like 'No Jira key*') {
            $findings += New-Finding 'high' 'Jira Alignment' 'PR is not traceable to a Jira issue' $message 'Add the Jira key to the PR title, body, branch name, or commits and verify the Java implementation scope matches that issue.' (@($JiraKeys))
        } elseif ($message -like 'Multiple Jira keys*') {
            $findings += New-Finding 'medium' 'Jira Alignment' 'Multiple Jira issues are linked to one PR' $message 'Confirm whether the PR intentionally spans multiple Jira issues; otherwise split the work or document the Java service scope boundary.' (@($JiraKeys))
        } elseif ($message -like '*weak term overlap*') {
            $findings += New-Finding 'medium' 'Jira Alignment' 'PR title and Jira intent look weakly aligned' $message 'Clarify the PR title and description so reviewers can map the Java or Spring implementation to the Jira intent without inference.' (@($JiraKeys))
        } else {
            $findings += New-Finding 'medium' 'Jira Alignment' 'Jira context is incomplete' $message 'Load or document the missing Jira context before approving the Java service change.' (@($JiraKeys))
        }
    }
    foreach ($message in $RiskFindings) {
        if ($message.StartsWith('No obvious')) { continue }
        if ($message -like 'Large change set*') {
            $findings += New-Finding 'medium' 'Implementation Risk' 'Large change set increases review surface' $message 'Break the PR into smaller units or add stronger Java-focused reviewer guidance and regression coverage.' @($message)
        } elseif ($message -like 'Risky paths touched*') {
            $findings += New-Finding 'high' 'Implementation Risk' 'High-risk production paths were modified' $message 'Add targeted validation for the risky Java or Spring paths and confirm rollout, rollback, and failure handling.' @($message)
        } elseif ($message -like 'Production code changed without*') {
            $findings += New-Finding 'high' 'Implementation Risk' 'Production code changed without matching tests' $message 'Add or update regression tests that exercise the changed Java production paths before merge.' @($message)
        } else {
            $findings += New-Finding 'medium' 'Implementation Risk' 'PR carries implementation risk' $message 'Document the operational risk and add missing validation before approving the Java service change.' @($message)
        }
    }
    $findings += @($CodeFindingObjects)
    foreach ($message in $TestFindings) {
        if ($message.StartsWith('Observed') -or $message.StartsWith('No executable')) { continue }
        if ($message.StartsWith('Code changed without')) {
            $findings += New-Finding 'high' 'Test Gap' 'Test coverage is missing for changed implementation' $message 'Add tests that cover the modified Java or Spring behavior before merging.' @($message)
        } elseif ($message.StartsWith('Test Gap: ')) {
            $title = $message.Substring(10)
            $findings += New-Finding 'medium' 'Test Gap' $title $message ('Implement: ' + $title) @($message)
        } else {
            $findings += New-Finding 'medium' 'Test Gap' $message $message 'Add the missing regression coverage described by this gap before approval.' @($message)
        }
    }
    foreach ($excerpt in @($ReviewCommentExcerpts | Select-Object -First 4)) {
        $findings += New-Finding 'medium' 'Reviewer Concern' 'Reviewer raised an unresolved question' $excerpt 'Address the reviewer concern directly in Java or Spring code, tests, or PR discussion before approval.' @($excerpt)
    }
    foreach ($excerpt in @($IssueCommentExcerpts | Select-Object -First 2)) {
        $findings += New-Finding 'medium' 'Reviewer Concern' 'Issue comment adds unresolved acceptance concern' $excerpt 'Close the acceptance concern explicitly in code, configuration, or tests.' @($excerpt)
    }
    $sorted = Sort-Findings $findings
    $summary = @($sorted | ForEach-Object {
        [ordered]@{
            severity = $_.severity
            category = $_.category
            title = $_.title
            summary = $_.summary
            suggested_fix = $_.suggested_fix
            evidence_refs = $_.evidence_refs
        }
    })
    return @{ detailed = $sorted; summary = $summary }
}

function Render-Markdown([hashtable]$Report) {
    $pull = $Report.pull
    $analysis = $Report.analysis
    $severityEmoji = @{ critical = '🔴'; high = '🟠'; medium = '🟡'; low = '🟢' }
    $severityLabel = @{ critical = 'Critical'; high = 'High'; medium = 'Medium'; low = 'Low' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        '# PR Review',
        '',
        '## Review Scope',
        "- PR: $($Report.pr_url)",
        "- Mode: $($Report.mode_used)",
        "- Generated at: $($Report.generated_at)",
        "- Reviewer: $($analysis.code_review_reviewer)",
        "- Code review mode: $($analysis.code_review_mode) (diff-based, no AST/compiler)",
        "- Supported targets: $((@($analysis.code_review_supported_targets) -join ', '))",
        "- Title: $($pull.title)",
        "- Author: $($pull.author)",
        ('- Branches: `{0}` -> `{1}`' -f $pull.head_ref, $pull.base_ref),
        "- Size: $($pull.changed_files) files, +$($pull.additions) / -$($pull.deletions) ($($pull.churn) lines)"
    )) { [void]$lines.Add($line) }
    if ($Report.prompt_text) { [void]$lines.Add("- Request: $($Report.prompt_text)") }
    if ($Report.PSObject.Properties.Name -contains 'orchestration') { [void]$lines.Add("- Subagent plan: $(if ($Report.orchestration.use_subagents) { 'enabled' } else { 'local-only' })") }
    [void]$lines.Add('')
    [void]$lines.Add('## Findings Summary')
    if (@($analysis.findings_summary).Count -eq 0) {
        [void]$lines.Add('- 🟢 No high-severity findings were detected automatically.')
    } else {
        foreach ($item in @($analysis.findings_summary)) {
            [void]$lines.Add("- $($severityEmoji[$item.severity]) **$($severityLabel[$item.severity])** [$($item.category)] $($item.title)")
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Detailed Analysis And Suggested Fixes')
    foreach ($item in @($analysis.detailed_findings)) {
        foreach ($line in @(
            "### $($severityEmoji[$item.severity]) $($item.title)",
            "- Severity: $($severityLabel[$item.severity])",
            "- Category: $($item.category)",
            "- Analysis: $($item.details)",
            "- Suggested change: $($item.suggested_fix)",
            "- Evidence: $((@($item.evidence_refs) -join ' | '))",
            ''
        )) { [void]$lines.Add($line) }
    }
    if (@($analysis.detailed_findings).Count -eq 0) {
        [void]$lines.Add('No actionable findings were detected automatically.')
    }
    [void]$lines.Add('## Evidence Sources')
    $sources = $Report.evidence.sources
    [void]$lines.Add('### PR')
    [void]$lines.Add("- URL: $($sources.pr.url)")
    [void]$lines.Add("- Title: $($sources.pr.title)")
    [void]$lines.Add("- Author: $($sources.pr.author)")
    [void]$lines.Add(('- Branches: `{0}` -> `{1}`' -f $sources.pr.head_ref, $sources.pr.base_ref))
    [void]$lines.Add("- Size scanned: $($sources.pr.changed_files) files / $($sources.pr.churn) lines")
    [void]$lines.Add('')
    [void]$lines.Add('### Jira')
    if (@($sources.jira).Count -gt 0) {
        foreach ($issue in @($sources.jira)) {
            [void]$lines.Add(('- `{0}`: {1} ({2}, {3}, assignee: {4}, comments scanned: {5})' -f $issue.key, $issue.title, $issue.status, $issue.priority, $issue.assignee, $issue.comment_count))
        }
    } else {
        [void]$lines.Add('- No Jira issues were loaded.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('### Commits')
    if (@($sources.commits).Count -gt 0) {
        foreach ($message in @($sources.commits)) { [void]$lines.Add("- $message") }
    } else {
        [void]$lines.Add('- No commit messages were captured.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('### Comments')
    if (@($sources.comments.review_comments).Count -gt 0) {
        [void]$lines.Add('- Review comments scanned:')
        foreach ($item in @($sources.comments.review_comments)) { [void]$lines.Add("  - $item") }
    }
    if (@($sources.comments.issue_comments).Count -gt 0) {
        [void]$lines.Add('- Issue comments scanned:')
        foreach ($item in @($sources.comments.issue_comments)) { [void]$lines.Add("  - $item") }
    }
    if (@($sources.comments.review_comments).Count -eq 0 -and @($sources.comments.issue_comments).Count -eq 0) {
        [void]$lines.Add('- No PR comments were captured.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('### Diff Files')
    if (@($sources.files).Count -gt 0) {
        foreach ($fileEntry in @($sources.files)) {
            $kind = if ($fileEntry.is_test) { 'test' } elseif ($fileEntry.is_doc) { 'doc' } else { 'code' }
            $patchStatus = if ($fileEntry.has_patch) { 'patch' } else { 'metadata-only' }
            [void]$lines.Add("- $($fileEntry.filename) ($kind, $($fileEntry.language), $patchStatus, target: $($fileEntry.review_target))")
        }
    } else {
        [void]$lines.Add('- No changed files were captured.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Recommendation')
    [void]$lines.Add("- $($analysis.recommendation)")
    [void]$lines.Add('')
    [void]$lines.Add('## Positive Signals')
    foreach ($item in @($analysis.positives)) { [void]$lines.Add("- $item") }
    return (($lines -join "`n").Trim() + "`n")
}
function Analyze-Bundle([object]$Bundle, [string]$ResolvedMode, [string]$ResolvedPromptText) {
    $pull = $Bundle.pull
    $files = @($Bundle.files)
    $commits = @($Bundle.commits)
    $issueComments = @($Bundle.issue_comments)
    $reviewComments = @($Bundle.review_comments)
    $jiraKeys = @()
    if ($Bundle.PSObject.Properties.Name -contains 'jira_keys') { $jiraKeys = @($Bundle.jira_keys) } elseif ($Bundle.PSObject.Properties.Name -contains 'jira_issues') { $jiraKeys = @($Bundle.jira_issues.PSObject.Properties.Name) }
    $jiraIssues = @()
    foreach ($key in $jiraKeys) {
        if ($Bundle.jira_issues.PSObject.Properties.Name -contains $key) {
            $jiraIssues += Get-JiraIssueSummary $Bundle.jira_issues.$key
        }
    }
    $diff = Get-DiffEvidence $files
    $riskyPaths = @($files | Where-Object {
        $path = [string]$_.filename
        $reviewTarget = Get-JavaReviewTarget $path
        @(@($HighRiskPathHints | Where-Object { $path.ToLowerInvariant().Contains($_) })).Count -gt 0 -or $reviewTarget -in @('spring-config', 'build-config', 'logging-config')
    } | ForEach-Object { $_.filename })
    $churn = [int](Get-ValueOrDefault $pull.additions 0) + [int](Get-ValueOrDefault $pull.deletions 0)
    $alignmentFindings = @()
    if ($jiraKeys.Count -eq 0) { $alignmentFindings += 'No Jira key was found in the PR title, branch name, body, or commit messages.' }
    elseif ($jiraKeys.Count -gt 1) { $alignmentFindings += "Multiple Jira keys were detected: $($jiraKeys -join ', ')." }
    if ($jiraKeys.Count -gt 0 -and $jiraIssues.Count -eq 0) { $alignmentFindings += 'Jira keys were detected, but no Jira issue details were loaded.' }
    $titleTokens = Tokenize ([string]$pull.title)
    foreach ($issue in $jiraIssues) {
        $jiraTokens = Tokenize ($issue.title + ' ' + $issue.description_text + ' ' + (@($issue.comment_excerpts) -join ' '))
        $overlap = @($titleTokens | Where-Object { $jiraTokens.Contains($_) })
        if ($overlap.Count -lt 2) { $alignmentFindings += "$($issue.key) has weak term overlap with the PR title; verify the implementation scope manually." }
        if (-not $issue.description_text) { $alignmentFindings += "$($issue.key) does not expose a Jira description; confirm intent from Jira comments or linked docs." }
    }
    $positives = @()
    if ($jiraKeys.Count -gt 0) { $positives += "Detected Jira link(s): $($jiraKeys -join ', ')." }
    $positives += @($diff.positives | Where-Object { $_ -notin $positives })
    if ($positives.Count -eq 0) { $positives = @('No positive signals were detected automatically.') }
    $riskFindings = @()
    $riskLevel = 'Low'
    if ($pull.draft) { $riskFindings += 'The PR is still marked as draft.'; $riskLevel = 'Medium' }
    if ($churn -ge 600 -or $files.Count -gt 15) { $riskFindings += "Large change set: $($files.Count) files and $churn lines of churn."; $riskLevel = 'High' }
    if ($riskyPaths.Count -gt 0) { $riskFindings += "Risky paths touched: $($riskyPaths -join ', ')."; $riskLevel = 'High' }
    if ($diff.code_files.Count -gt 0 -and $diff.test_files.Count -eq 0) { $riskFindings += 'Production code changed without matching test file updates.'; if ($riskLevel -eq 'Low') { $riskLevel = 'High' } }
    if ($riskFindings.Count -eq 0) { $riskFindings += 'No obvious high-risk path or unusually large churn was detected from metadata alone.' }
    $testFindings = @()
    if ($diff.code_files.Count -gt 0 -and $diff.test_files.Count -eq 0) { $testFindings += 'Code changed without any matching test file updates.' }
    elseif ($diff.test_files.Count -gt 0) { $testFindings += "Observed $($diff.test_files.Count) test file change(s) alongside the implementation." }
    else { $testFindings += 'No executable code changes were detected.' }
    foreach ($suggestion in Get-JavaExpertTestSuggestions $diff.reviewed_targets $diff.code_files $diff.test_files $riskyPaths) {
        $testFindings += "Test Gap: $suggestion"
    }
    $issueCommentExcerpts = Get-CommentExcerpts $issueComments 6
    $reviewCommentExcerpts = Get-CommentExcerpts $reviewComments 6
    $openQuestions = @($diff.questions + $reviewCommentExcerpts + $issueCommentExcerpts)
    if ($openQuestions.Count -eq 0) { $openQuestions = @('No reviewer or issue comments were captured.') }
    $recommendation = 'Approve with normal review'
    if ($jiraKeys.Count -eq 0 -or ($riskLevel -eq 'High' -and $diff.test_files.Count -eq 0)) { $recommendation = 'Request changes' }
    elseif ($riskLevel -in @('High', 'Medium') -or $alignmentFindings.Count -gt 0) { $recommendation = 'Needs clarification' }
    $structured = Build-StructuredFindings $jiraKeys $alignmentFindings $riskFindings $diff.code_finding_objects $testFindings $issueCommentExcerpts $reviewCommentExcerpts
    $fallbackCodeFinding = if ($diff.supported_file_count -eq 0) { 'No Java ecosystem files were eligible for expert diff review; non-Java files were only evaluated for metadata-level risk.' } else { 'No actionable Java expert diff findings were detected automatically.' }
    return [ordered]@{
        generated_at = [DateTime]::UtcNow.ToString('o')
        mode_used = $ResolvedMode
        prompt_text = $ResolvedPromptText
        pr_url = if ($Bundle.pr_url) { $Bundle.pr_url } else { $pull.html_url }
        pull = [ordered]@{
            number = $pull.number
            title = if ($pull.title) { $pull.title } else { 'Unknown PR' }
            author = if ($pull.PSObject.Properties.Name -contains 'user' -and $pull.user.PSObject.Properties.Name -contains 'login') { $pull.user.login } else { 'unknown' }
            state = if ($pull.state) { $pull.state } else { 'unknown' }
            draft = [bool]$pull.draft
            head_ref = if ($pull.head.ref) { $pull.head.ref } else { '' }
            base_ref = if ($pull.base.ref) { $pull.base.ref } else { '' }
            changed_files = if ($files.Count -gt 0) { $files.Count } else { [int](Get-ValueOrDefault $pull.changed_files 0) }
            additions = [int](Get-ValueOrDefault $pull.additions 0)
            deletions = [int](Get-ValueOrDefault $pull.deletions 0)
            churn = $churn
            sample_files = @($files | Select-Object -First 5 | ForEach-Object { $_.filename })
            commit_count = $commits.Count
            languages = $diff.languages
        }
        jira_keys = $jiraKeys
        jira_issues = $jiraIssues
        evidence = [ordered]@{
            files = @($diff.files | Select-Object -First 40)
            commit_messages = @($commits | Select-Object -First 10 | ForEach-Object { $_.commit.message })
            issue_comments = $issueCommentExcerpts
            review_comments = $reviewCommentExcerpts
            sources = Get-EvidenceSources $(if ($Bundle.pr_url) { $Bundle.pr_url } else { $pull.html_url }) $pull $jiraIssues $commits $issueComments $reviewComments $diff
        }
        analysis = [ordered]@{
            positives = $positives
            alignment_findings = if ($alignmentFindings.Count -gt 0) { $alignmentFindings } else { @('No obvious Jira alignment gaps were detected from the available metadata.') }
            risk_level = $riskLevel
            risk_findings = $riskFindings
            code_review_mode = $CodeReviewMode
            code_review_reviewer = $CodeReviewReviewer
            code_review_supported_targets = $CodeReviewSupportedTargets
            code_evidence = $diff.code_evidence
            code_findings = if ($diff.code_findings.Count -gt 0) { $diff.code_findings } else { @($fallbackCodeFinding) }
            test_findings = $testFindings
            open_questions = @($openQuestions | Select-Object -First 8)
            recommendation = $recommendation
            findings_summary = $structured.summary
            detailed_findings = $structured.detailed
        }
    }
}

try {
    if (-not $InputPath) { throw 'Provide -InputPath with a combined bundle JSON file.' }
    $bundle = Get-Json $InputPath
    $resolvedMode = if ($ModeUsed) { $ModeUsed } elseif ($bundle.PSObject.Properties.Name -contains 'mode_used') { $bundle.mode_used } else { 'unknown' }
    $resolvedPrompt = $null
    if ($PromptText) { $resolvedPrompt = $PromptText } elseif ($bundle.PSObject.Properties.Name -contains 'prompt_text') { $resolvedPrompt = $bundle.prompt_text }
    $report = Analyze-Bundle $bundle $resolvedMode $resolvedPrompt
    $markdown = Render-Markdown $report
    if ($DraftPath) {
        $resolvedDraft = Write-TextFile $DraftPath $markdown
        $report.draft = [ordered]@{
            draft_path = $resolvedDraft
            pr_url = $report.pr_url
            generated_at = [DateTime]::UtcNow.ToString('o')
            source_mode = $report.mode_used
        }
    }
    if ($OutputFormat -eq 'json') {
        $report | ConvertTo-Json -Depth 100
    } else {
        Write-Output $markdown
    }
} catch {
    Fail $_.Exception.Message
}



