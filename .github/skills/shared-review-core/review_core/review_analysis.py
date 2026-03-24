from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .jira_context import extract_jira_keys, summarize_jira_issue

TEST_PATH_RE = re.compile(r"(^|/)(tests?|__tests__)/|(_test|_spec)\.|(\.test\.|\.spec\.)", re.IGNORECASE)
DOC_EXTENSIONS = {".md", ".txt", ".rst", ".adoc"}
HIGH_RISK_PATH_HINTS = (
    "migration",
    "schema",
    "payment",
    "billing",
    "auth",
    "permission",
    "security",
    "terraform",
    "k8s",
    "helm",
    "config",
    "sql",
)
STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "for",
    "from",
    "the",
    "this",
    "that",
    "with",
    "into",
    "when",
    "during",
    "still",
    "does",
    "not",
}
LANGUAGE_BY_EXTENSION = {
    ".py": "Python",
    ".java": "Java",
}
SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}

CATEGORY_ORDER = {
    "Jira Alignment": 0,
    "Implementation Risk": 1,
    "Code Quality": 2,
    "Test Gap": 3,
    "Reviewer Concern": 4,
}


def combine_bundles(github_bundle: dict[str, Any], jira_bundle: dict[str, Any]) -> dict[str, Any]:
    combined = dict(github_bundle)
    combined["jira_keys"] = jira_bundle.get("jira_keys", [])
    combined["jira_issues"] = jira_bundle.get("jira_issues", {})
    return combined


def _tokenize(text: str) -> set[str]:
    return {
        token
        for token in re.findall(r"[a-z0-9]+", (text or "").lower())
        if len(token) > 2 and token not in STOPWORDS and not token.isdigit()
    }


def _is_test_file(path: str) -> bool:
    return bool(TEST_PATH_RE.search(path.replace("\\", "/")))


def _is_doc_file(path: str) -> bool:
    normalized = path.replace("\\", "/").lower()
    return Path(path).suffix.lower() in DOC_EXTENSIONS or normalized.startswith(("docs/", "doc/"))


def _comment_excerpt(comments: list[dict[str, Any]]) -> list[str]:
    excerpts = []
    for comment in comments[:6]:
        author = comment.get("user", {}).get("login", comment.get("author", {}).get("displayName", "unknown"))
        body = " ".join(str(comment.get("body", "")).split())
        if body:
            excerpts.append(f"{author}: {body[:157] + '...' if len(body) > 160 else body}")
    return excerpts


def _detect_languages(files: list[dict[str, Any]]) -> list[str]:
    languages = {
        LANGUAGE_BY_EXTENSION[Path(item.get("filename", "")).suffix.lower()]
        for item in files
        if Path(item.get("filename", "")).suffix.lower() in LANGUAGE_BY_EXTENSION
    }
    return sorted(languages)


def _patch_excerpt(patch: str, max_lines: int = 16, max_chars: int = 1400) -> str:
    if not patch:
        return ""
    lines = []
    for line in patch.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith(("@@", "+", "-")):
            lines.append(line)
        if len(lines) >= max_lines:
            break
    excerpt = "\n".join(lines).strip()
    if len(excerpt) > max_chars:
        excerpt = excerpt[: max_chars - 3].rstrip() + "..."
    return excerpt


def _heuristic_code_findings(file_entry: dict[str, Any]) -> list[str]:
    findings = []
    filename = file_entry["filename"]
    patch_excerpt = file_entry["patch_excerpt"]
    lowered = patch_excerpt.lower()
    if "todo" in lowered:
        findings.append(f"{filename}: diff still contains a TODO marker, so the implementation may not be production-complete.")
    if "except Exception" in patch_excerpt:
        findings.append(f"{filename}: broad `except Exception` handling may hide failure causes and make retries harder to reason about.")
    if re.search(r"def\s+\w+\([^)]*=\[\]", patch_excerpt):
        findings.append(f"{filename}: mutable default list argument can leak state across calls.")
    if "logger.info" in patch_excerpt and "token" in lowered:
        findings.append(f"{filename}: logging token-related state deserves a quick review to avoid leaking sensitive request context.")
    return findings


def _collect_diff_evidence(files: list[dict[str, Any]]) -> dict[str, Any]:
    languages = _detect_languages(files)
    evidence_files = []
    code_files = []
    test_files = []
    doc_files = []
    patch_files = []
    code_findings = []

    for item in files:
        filename = item.get("filename", "")
        path_obj = Path(filename)
        language = LANGUAGE_BY_EXTENSION.get(path_obj.suffix.lower(), "Unknown")
        is_test = _is_test_file(filename)
        is_doc = _is_doc_file(filename)
        has_patch = bool(item.get("patch"))
        file_entry = {
            "filename": filename,
            "status": item.get("status", "modified"),
            "additions": int(item.get("additions", 0)),
            "deletions": int(item.get("deletions", 0)),
            "language": language,
            "is_test": is_test,
            "is_doc": is_doc,
            "has_patch": has_patch,
            "patch_excerpt": _patch_excerpt(item.get("patch", "") or ""),
        }
        evidence_files.append(file_entry)
        if is_test:
            test_files.append(file_entry)
        elif is_doc:
            doc_files.append(file_entry)
        else:
            code_files.append(file_entry)
        if has_patch:
            patch_files.append(file_entry)
            code_findings.extend(_heuristic_code_findings(file_entry))

    code_evidence = []
    if languages:
        code_evidence.append(f"Detected code languages in changed files: {', '.join(languages)}.")
    if patch_files:
        patch_sample = ", ".join(item["filename"] for item in patch_files[:4])
        code_evidence.append(f"Inline patch excerpts are available for {len(patch_files)} file(s): {patch_sample}.")
    else:
        code_evidence.append("No inline patch excerpt was returned by GitHub for code-level inspection.")
    if code_files:
        changed_sample = ", ".join(item["filename"] for item in code_files[:5])
        code_evidence.append(f"Changed production files: {changed_sample}.")
    if test_files:
        test_sample = ", ".join(item["filename"] for item in test_files[:4])
        code_evidence.append(f"Changed test files: {test_sample}.")
    if doc_files:
        doc_sample = ", ".join(item["filename"] for item in doc_files[:3])
        code_evidence.append(f"Changed documentation files: {doc_sample}.")

    positives = []
    if test_files:
        positives.append(f"Test files changed: {', '.join(item['filename'] for item in test_files[:3])}.")
    if doc_files:
        positives.append(f"Documentation/runbook updates present: {', '.join(item['filename'] for item in doc_files[:2])}.")
    if patch_files:
        positives.append(f"Diff evidence captured patch excerpts for {len(patch_files)} file(s).")

    questions = []
    if patch_files and code_files:
        for item in patch_files[:3]:
            questions.append(f"What changed semantically in {item['filename']} and how is it validated?")

    return {
        "languages": languages,
        "files": evidence_files,
        "code_files": code_files,
        "test_files": test_files,
        "doc_files": doc_files,
        "patch_files": patch_files,
        "code_evidence": code_evidence,
        "code_findings": code_findings,
        "positives": positives,
        "questions": questions,
    }


def _generate_test_suggestions(*, languages: list[str], code_files: list[dict[str, Any]], test_files: list[dict[str, Any]], risky_paths: list[str]) -> list[str]:
    suggestions: list[str] = []
    seen: set[str] = set()

    def add(item: str) -> None:
        if item not in seen:
            seen.add(item)
            suggestions.append(item)

    if code_files and not test_files:
        add("Add targeted regression tests for the changed production paths because no test files changed.")
    if "Python" in languages:
        add("Add Python coverage for changed branches, error handling, and repeated-call behavior visible in the diff.")
    if "Java" in languages:
        add("Add Java coverage for changed branches, exception handling, and state transitions visible in the diff.")
    if any(any(token in path.lower() for token in ("payment", "billing")) for path in risky_paths):
        add("Add an integration test covering duplicate events, retries, idempotency, and downstream side effects for payment-related paths.")
    if any(any(token in path.lower() for token in ("migration", "sql", "schema")) for path in risky_paths):
        add("Add a migration compatibility test covering existing rows, rollout, rollback, and read/write compatibility.")
    if any(any(token in path.lower() for token in ("auth", "permission", "security")) for path in risky_paths):
        add("Add authorization and negative-path tests proving unsafe callers are rejected.")
    if not suggestions and code_files:
        add("Add focused unit tests around changed methods plus one end-to-end regression covering the primary business flow.")
    return suggestions[:8]


def _make_finding(*, severity: str, category: str, title: str, details: str, suggested_fix: str, evidence_refs: list[str]) -> dict[str, Any]:
    return {
        "severity": severity,

        "category": category,
        "title": title,
        "summary": title,
        "details": details,
        "suggested_fix": suggested_fix,
        "evidence_refs": evidence_refs,
    }


def _sort_findings(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        findings,
        key=lambda item: (
            SEVERITY_ORDER[item["severity"]],
            CATEGORY_ORDER.get(item["category"], 99),
            item["title"],
        ),
    )


def _build_evidence_sources(
    *,
    report_pr_url: str | None,
    pull: dict[str, Any],
    jira_issues: list[dict[str, Any]],
    commits: list[dict[str, Any]],
    issue_comments: list[dict[str, Any]],
    review_comments: list[dict[str, Any]],
    diff_evidence: dict[str, Any],
) -> dict[str, Any]:
    return {
        "pr": {
            "url": report_pr_url,
            "title": pull.get("title", "Unknown PR"),
            "author": pull.get("user", {}).get("login", "unknown"),
            "head_ref": pull.get("head", {}).get("ref", ""),
            "base_ref": pull.get("base", {}).get("ref", ""),
            "changed_files": len(diff_evidence["files"]) or int(pull.get("changed_files", 0)),
            "churn": int(pull.get("additions", 0)) + int(pull.get("deletions", 0)),
        },
        "jira": [
            {
                "key": issue["key"],
                "title": issue["title"],
                "status": issue["status"],
                "priority": issue["priority"],
                "assignee": issue["assignee"],
                "description_available": bool(issue["description_text"]),
                "comment_count": len(issue["comment_excerpts"]),
            }
            for issue in jira_issues
        ],
        "commits": [commit.get("commit", {}).get("message", "") for commit in commits[:10]],
        "comments": {
            "issue_comments": _comment_excerpt(issue_comments),
            "review_comments": _comment_excerpt(review_comments),
        },
        "files": [
            {
                "filename": file_entry["filename"],
                "language": file_entry["language"],
                "is_test": file_entry["is_test"],
                "is_doc": file_entry["is_doc"],
                "has_patch": file_entry["has_patch"],
            }
            for file_entry in diff_evidence["files"][:20]
        ],
    }


def _build_structured_findings(
    *,
    jira_keys: list[str],
    jira_issues: list[dict[str, Any]],
    alignment_findings: list[str],
    risk_findings: list[str],
    risk_level: str,
    code_findings: list[str],
    test_findings: list[str],
    issue_comment_excerpts: list[str],
    review_comment_excerpts: list[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    findings: list[dict[str, Any]] = []

    for message in alignment_findings:
        if message.startswith("No obvious"):
            continue
        if "No Jira key" in message:
            severity = "high"
            title = "PR is not traceable to a Jira issue"
            fix = "Add the Jira key to the PR title, body, branch name, or commits and verify the implementation scope matches that issue."
        elif "Multiple Jira keys" in message:
            severity = "medium"
            title = "Multiple Jira issues are linked to one PR"
            fix = "Confirm whether the PR intentionally spans multiple Jira issues; otherwise split the work or document the scope boundary."
        elif "weak term overlap" in message:
            severity = "medium"
            title = "PR title and Jira intent look weakly aligned"
            fix = "Clarify the PR title and description so reviewers can map the implementation to the Jira intent without inference."
        else:
            severity = "medium"
            title = "Jira context is incomplete"
            fix = "Load or document the missing Jira context before approving the change."
        findings.append(_make_finding(
            severity=severity,
            category="Jira Alignment",
            title=title,
            details=message,
            suggested_fix=fix,
            evidence_refs=jira_keys or ["No Jira keys detected in PR metadata."],
        ))

    for message in risk_findings:
        if "No obvious high-risk" in message:
            continue
        if "Large change set" in message:
            severity = "medium"
            title = "Large change set increases review surface"
            fix = "Break the PR into smaller units or add stronger reviewer guidance and focused regression coverage."
        elif "Risky paths touched" in message:
            severity = "high"
            title = "High-risk production paths were modified"
            fix = "Add targeted validation for the risky paths and confirm rollout, rollback, and failure handling."
        elif "without matching test file updates" in message:
            severity = "high"
            title = "Production code changed without matching tests"
            fix = "Add or update regression tests that exercise the changed production paths before merge."
        else:
            severity = "medium" if risk_level != "High" else "high"
            title = "PR carries implementation risk"
            fix = "Document the operational risk and add missing validation before approval."
        findings.append(_make_finding(
            severity=severity,
            category="Implementation Risk",
            title=title,
            details=message,
            suggested_fix=fix,
            evidence_refs=[message],
        ))

    for message in code_findings:
        prefix, _, detail = message.partition(": ")
        detail_text = detail or message
        if "broad `except Exception`" in message or "mutable default" in message:
            severity = "high"
        elif "token-related" in message or "TODO marker" in message:
            severity = "medium"
        else:
            severity = "medium"
        if "broad `except Exception`" in message:
            fix = "Catch the narrowest expected exception type and add logging or error propagation that preserves failure context."
        elif "mutable default" in message:
            fix = "Replace the mutable default with `None`, then initialize the collection inside the function body."
        elif "TODO marker" in message:
            fix = "Resolve the TODO before merge or convert it into a tracked follow-up issue with explicit scope and owner."
        elif "token-related" in message:
            fix = "Review the log statement and avoid logging sensitive request context or tokens."
        else:
            fix = "Tighten the implementation and add a focused regression test for this code path."
        findings.append(_make_finding(
            severity=severity,
            category="Code Quality",
            title=detail_text,
            details=message,
            suggested_fix=fix,
            evidence_refs=[prefix] if prefix and prefix != message else [message],
        ))

    for message in test_findings:
        if message.startswith("Observed") or message.startswith("No executable"):
            continue
        if message.startswith("Code changed without"):
            severity = "high"
            title = "Test coverage is missing for changed implementation"
            fix = "Add tests that cover the modified production behavior before merging."
        elif message.startswith("Test Gap:"):
            severity = "medium"
            title = message.replace("Test Gap: ", "")
            fix = message.replace("Test Gap: ", "Implement: ")
        else:
            severity = "medium"
            title = message
            fix = "Add the missing regression coverage described by this gap before approval."
        findings.append(_make_finding(
            severity=severity,
            category="Test Gap",
            title=title,
            details=message,
            suggested_fix=fix,
            evidence_refs=[message],
        ))

    for excerpt in review_comment_excerpts[:4]:
        findings.append(_make_finding(
            severity="medium",
            category="Reviewer Concern",
            title="Reviewer raised an unresolved question",
            details=excerpt,
            suggested_fix="Address the reviewer concern directly in code, tests, or PR discussion before approval.",
            evidence_refs=[excerpt],
        ))
    for excerpt in issue_comment_excerpts[:2]:
        findings.append(_make_finding(
            severity="medium",
            category="Reviewer Concern",
            title="Issue comment adds unresolved acceptance concern",
            details=excerpt,
            suggested_fix="Close the acceptance concern explicitly in the PR description, code, or tests.",
            evidence_refs=[excerpt],
        ))

    sorted_findings = _sort_findings(findings)
    findings_summary = [
        {
            "severity": item["severity"],

            "category": item["category"],
            "title": item["title"],
            "summary": item["summary"],
            "suggested_fix": item["suggested_fix"],
            "evidence_refs": item["evidence_refs"],
        }
        for item in sorted_findings
    ]
    return sorted_findings, findings_summary


def decide_subagent_plan(
    *,
    requested_mode: str,
    mode_used: str,
    prompt_text: str | None,
    pull: dict[str, Any],
    jira_keys: list[str],
) -> dict[str, Any]:
    reasons = []
    if requested_mode in {"real", "auto"}:
        reasons.append("Live or live-capable mode benefits from parallel context gathering.")
    if int(pull.get("changed_files", 0)) > 15 or int(pull.get("churn", 0)) >= 600:
        reasons.append("Large PR size crosses the threshold for parallel analysis.")
    if len(jira_keys) > 1:
        reasons.append("Multiple Jira keys were detected and can be investigated independently.")
    if prompt_text and re.search(r"\b(subagent|parallel|deep|depth|thorough)\b", prompt_text, re.IGNORECASE):
        reasons.append("The user explicitly asked for deeper or parallel review behavior.")
    use_subagents = bool(reasons) and mode_used != "mock-fallback"
    agents = []
    if use_subagents:
        agents = [
            {"name": "Agent A", "role": "GitHub Context Worker", "responsibility": "Fetch PR metadata, files, commits, and comments."},
            {"name": "Agent B", "role": "Jira Context Worker", "responsibility": "Extract Jira keys and gather issue context in parallel."},
            {"name": "Agent C", "role": "Review Analysis Worker", "responsibility": "Analyze the combined evidence once context workers complete."},
        ]
    return {
        "use_subagents": use_subagents,
        "requested_mode": requested_mode,
        "mode_used": mode_used,
        "reasons": reasons or ["Run locally in a single thread for this request."],
        "agents": agents,
    }


def analyze_bundle(bundle: dict[str, Any], env: dict[str, str], mode_used: str, prompt_text: str | None = None) -> dict[str, Any]:
    pull = bundle.get("pull", {})
    files = bundle.get("files", [])
    commits = bundle.get("commits", [])
    issue_comments = bundle.get("issue_comments", [])
    review_comments = bundle.get("review_comments", [])
    jira_keys = bundle.get("jira_keys") or extract_jira_keys(bundle)

    jira_raw = bundle.get("jira_issues", {})
    jira_issues = [summarize_jira_issue(jira_raw[key]) for key in jira_keys if key in jira_raw]
    diff_evidence = _collect_diff_evidence(files)

    code_files = diff_evidence["code_files"]
    test_files = diff_evidence["test_files"]
    risky_paths = [item.get("filename", "") for item in files if any(hint in item.get("filename", "").lower() for hint in HIGH_RISK_PATH_HINTS)]
    churn = int(pull.get("additions", 0)) + int(pull.get("deletions", 0))

    alignment_findings = []
    if not jira_keys:
        alignment_findings.append("No Jira key was found in the PR title, branch name, body, or commit messages.")
    elif len(jira_keys) > 1:
        alignment_findings.append(f"Multiple Jira keys were detected: {', '.join(jira_keys)}.")
    if jira_keys and not jira_issues:
        alignment_findings.append("Jira keys were detected, but no Jira issue details were loaded.")

    title_tokens = _tokenize(pull.get("title", ""))
    for issue in jira_issues:
        jira_tokens = _tokenize(issue["title"]) | _tokenize(issue["description_text"]) | _tokenize(" ".join(issue["comment_excerpts"]))
        overlap = title_tokens & jira_tokens
        if len(overlap) < 2:
            alignment_findings.append(f"{issue['key']} has weak term overlap with the PR title; verify the implementation scope manually.")
        if not issue["description_text"]:
            alignment_findings.append(f"{issue['key']} does not expose a Jira description; confirm intent from Jira comments or linked docs.")

    positives = []
    if jira_keys:
        positives.append(f"Detected Jira link(s): {', '.join(jira_keys)}.")
    positives.extend(item for item in diff_evidence["positives"] if item not in positives)

    risk_findings = []
    risk_level = "Low"
    if pull.get("draft"):
        risk_findings.append("The PR is still marked as draft.")
        risk_level = "Medium"
    if churn >= 600 or len(files) > 15:
        risk_findings.append(f"Large change set: {len(files)} files and {churn} lines of churn.")
        risk_level = "High"
    if risky_paths:
        risk_findings.append(f"Risky paths touched: {', '.join(risky_paths[:4])}.")
        risk_level = "High"
    if code_files and not test_files:
        risk_findings.append("Production code changed without matching test file updates.")
        risk_level = "High" if risk_level == "Low" else risk_level
    if not risk_findings:
        risk_findings.append("No obvious high-risk path or unusually large churn was detected from metadata alone.")

    test_findings = []
    if code_files and not test_files:
        test_findings.append("Code changed without any matching test file updates.")
    elif test_files:
        test_findings.append(f"Observed {len(test_files)} test file change(s) alongside the implementation.")
    else:
        test_findings.append("No executable code changes were detected.")

    test_suggestions = _generate_test_suggestions(
        languages=diff_evidence["languages"],
        code_files=code_files,
        test_files=test_files,
        risky_paths=risky_paths,
    )
    test_findings.extend(f"Test Gap: {item}" for item in test_suggestions)

    issue_comment_excerpts = _comment_excerpt(issue_comments)
    review_comment_excerpts = _comment_excerpt(review_comments)
    open_questions = []
    open_questions.extend(diff_evidence["questions"])
    open_questions.extend(review_comment_excerpts)
    open_questions.extend(issue_comment_excerpts)
    if not open_questions:
        open_questions.append("No reviewer or issue comments were captured.")

    recommendation = "Approve with normal review"
    if not jira_keys or (risk_level == "High" and not test_files):
        recommendation = "Request changes"
    elif risk_level in {"High", "Medium"} or alignment_findings:
        recommendation = "Needs clarification"

    detailed_findings, findings_summary = _build_structured_findings(
        jira_keys=jira_keys,
        jira_issues=jira_issues,
        alignment_findings=alignment_findings,
        risk_findings=risk_findings,
        risk_level=risk_level,
        code_findings=diff_evidence["code_findings"] or ["No concrete inline code findings were detected automatically."],
        test_findings=test_findings,
        issue_comment_excerpts=issue_comment_excerpts,
        review_comment_excerpts=review_comment_excerpts,
    )

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode_used": mode_used,
        "prompt_text": prompt_text,
        "pr_url": bundle.get("pr_url") or pull.get("html_url"),
        "pull": {
            "number": pull.get("number"),
            "title": pull.get("title", "Unknown PR"),
            "author": pull.get("user", {}).get("login", "unknown"),
            "state": pull.get("state", "unknown"),
            "draft": bool(pull.get("draft")),
            "head_ref": pull.get("head", {}).get("ref", ""),
            "base_ref": pull.get("base", {}).get("ref", ""),
            "changed_files": len(files) or int(pull.get("changed_files", 0)),
            "additions": int(pull.get("additions", 0)),
            "deletions": int(pull.get("deletions", 0)),
            "churn": churn,
            "sample_files": [item.get("filename", "") for item in files[:5]],
            "commit_count": len(commits),
            "languages": diff_evidence["languages"],
        },
        "jira_keys": jira_keys,
        "jira_issues": jira_issues,
        "evidence": {
            "files": diff_evidence["files"][:40],
            "commit_messages": [commit.get("commit", {}).get("message", "") for commit in commits[:10]],
            "issue_comments": issue_comment_excerpts,
            "review_comments": review_comment_excerpts,
            "sources": _build_evidence_sources(
                report_pr_url=bundle.get("pr_url") or pull.get("html_url"),
                pull=pull,
                jira_issues=jira_issues,
                commits=commits,
                issue_comments=issue_comments,
                review_comments=review_comments,
                diff_evidence=diff_evidence,
            ),
        },
        "analysis": {
            "positives": positives or ["No positive signals were detected automatically."],
            "alignment_findings": alignment_findings or ["No obvious Jira alignment gaps were detected from the available metadata."],
            "risk_level": risk_level,
            "risk_findings": risk_findings,
            "code_evidence": diff_evidence["code_evidence"],
            "code_findings": diff_evidence["code_findings"] or ["No concrete inline code findings were detected automatically."],
            "test_findings": test_findings,
            "open_questions": open_questions[:8],
            "recommendation": recommendation,
            "findings_summary": findings_summary,
            "detailed_findings": detailed_findings,
        },
    }

