$SharedJavaExpertAnalyzer = Join-Path $PSScriptRoot '..\..\..\..\pr-review-writer\scripts\analyzers\java\java_expert_analyzer.ps1'
if (-not (Test-Path $SharedJavaExpertAnalyzer)) {
    throw "Missing shared Java expert analyzer at $SharedJavaExpertAnalyzer"
}
. $SharedJavaExpertAnalyzer
