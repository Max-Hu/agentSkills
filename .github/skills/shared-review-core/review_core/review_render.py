from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .common import parse_pr_url, write_text
from .contracts import DraftMetadata

SEVERITY_EMOJI = {
    "critical": "🔴",
    "high": "🟠",
    "medium": "🟡",
    "low": "🟢",
}
SEVERITY_LABELS = {
    "critical": "Critical",
    "high": "High",
    "medium": "Medium",
    "low": "Low",
}


def _render_findings_summary(findings_summary: list[dict[str, Any]]) -> list[str]:
    if not findings_summary:
        return ["- 🟢 No high-severity findings were detected automatically."]
    return [
        f"- {SEVERITY_EMOJI[item['severity']]} **{SEVERITY_LABELS[item['severity']]}** [{item['category']}] {item['title']}"
        for item in findings_summary
    ]


def _render_detailed_findings(detailed_findings: list[dict[str, Any]]) -> list[str]:
    if not detailed_findings:
        return ["No actionable findings were detected automatically."]
    lines: list[str] = []
    for item in detailed_findings:
        lines.extend([
            f"### {SEVERITY_EMOJI[item['severity']]} {item['title']}",
            f"- Severity: {SEVERITY_LABELS[item['severity']]}",
            f"- Category: {item['category']}",
            f"- Analysis: {item['details']}",
            f"- Suggested change: {item['suggested_fix']}",
            f"- Evidence: {' | '.join(item['evidence_refs']) if item['evidence_refs'] else 'No direct evidence references captured.'}",
            "",
        ])
    return lines[:-1]


def _render_sources(report: dict[str, Any]) -> list[str]:
    sources = report["evidence"].get("sources", {})
    pr = sources.get("pr", {})
    jira = sources.get("jira", [])
    commits = sources.get("commits", [])
    comments = sources.get("comments", {})
    files = sources.get("files", [])

    lines = [
        "### PR",
        f"- URL: {pr.get('url', 'Unknown')}",
        f"- Title: {pr.get('title', 'Unknown PR')}",
        f"- Author: {pr.get('author', 'unknown')}",
        f"- Branches: `{pr.get('head_ref', '')}` -> `{pr.get('base_ref', '')}`",
        f"- Size scanned: {pr.get('changed_files', 0)} files / {pr.get('churn', 0)} lines",
        "",
        "### Jira",
    ]
    if jira:
        for issue in jira:
            lines.append(
                f"- `{issue['key']}`: {issue['title']} ({issue['status']}, {issue['priority']}, assignee: {issue['assignee']}, comments scanned: {issue['comment_count']})"
            )
    else:
        lines.append("- No Jira issues were loaded.")

    lines.extend(["", "### Commits"])
    if commits:
        lines.extend(f"- {message}" for message in commits)
    else:
        lines.append("- No commit messages were captured.")

    lines.extend(["", "### Comments"])
    review_comments = comments.get("review_comments", [])
    issue_comments = comments.get("issue_comments", [])
    if review_comments:
        lines.append("- Review comments scanned:")
        lines.extend(f"  - {item}" for item in review_comments)
    if issue_comments:
        lines.append("- Issue comments scanned:")
        lines.extend(f"  - {item}" for item in issue_comments)
    if not review_comments and not issue_comments:
        lines.append("- No PR comments were captured.")

    lines.extend(["", "### Diff Files"])
    if files:
        for file_entry in files:
            kind = "test" if file_entry["is_test"] else "doc" if file_entry["is_doc"] else "code"
            patch_status = "patch" if file_entry["has_patch"] else "metadata-only"
            lines.append(f"- {file_entry['filename']} ({kind}, {file_entry['language']}, {patch_status})")
    else:
        lines.append("- No changed files were captured.")
    return lines


def render_markdown(report: dict[str, Any]) -> str:
    pull = report["pull"]
    analysis = report["analysis"]

    sections = [
        "# PR Review",
        "",
        "## Review Scope",
        f"- PR: {report['pr_url']}",
        f"- Mode: {report['mode_used']}",
        f"- Generated at: {report['generated_at']}",
        f"- Title: {pull['title']}",
        f"- Author: {pull['author']}",
        f"- Branches: `{pull['head_ref']}` -> `{pull['base_ref']}`",
        f"- Size: {pull['changed_files']} files, +{pull['additions']} / -{pull['deletions']} ({pull['churn']} lines)",
    ]
    if report.get("prompt_text"):
        sections.append(f"- Request: {report['prompt_text']}")
    if report.get("orchestration"):
        sections.append(f"- Subagent plan: {'enabled' if report['orchestration']['use_subagents'] else 'local-only'}")

    sections.extend([
        "",
        "## Findings Summary",
        *_render_findings_summary(analysis.get("findings_summary", [])),
        "",
        "## Detailed Analysis And Suggested Fixes",
        *_render_detailed_findings(analysis.get("detailed_findings", [])),
        "",
        "## Evidence Sources",
        *_render_sources(report),
        "",
        "## Recommendation",
        f"- {analysis['recommendation']}",
        "",
        "## Positive Signals",
        *[f"- {item}" for item in analysis["positives"]],
    ])
    return "\n".join(sections).strip() + "\n"


def derive_default_draft_path(pr_url: str | None) -> Path:
    if pr_url:
        try:
            pr_ref = parse_pr_url(pr_url)
            filename = f"{pr_ref.owner}-{pr_ref.repo}-pr-{pr_ref.number}-review.md"
        except Exception:
            filename = "pr-review.md"
    else:
        filename = "pr-review.md"
    return Path.cwd() / "pr-review-drafts" / filename


def write_review_draft(markdown: str, *, pr_url: str, source_mode: str, draft_path: str | Path | None = None) -> dict[str, Any]:
    resolved = write_text(draft_path or derive_default_draft_path(pr_url), markdown)
    metadata = DraftMetadata(
        draft_path=str(resolved),
        pr_url=pr_url,
        generated_at=datetime.now(timezone.utc).isoformat(),
        source_mode=source_mode,
    )
    return metadata.to_dict()
