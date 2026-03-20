from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, parse, request

PR_URL_RE = re.compile(r"https?://[^\s]+/[^/\s]+/[^/\s]+/pull/\d+")
JIRA_KEY_RE = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")
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


class ReviewError(RuntimeError):
    pass


@dataclass(frozen=True)
class PullRequestRef:
    host: str
    owner: str
    repo: str
    number: int
    url: str


def extract_pr_url(text: str) -> str | None:
    match = PR_URL_RE.search(text or "")
    return match.group(0) if match else None


def parse_pr_url(url: str) -> PullRequestRef:
    parsed = parse.urlparse(url)
    parts = [part for part in parsed.path.split("/") if part]
    if parsed.scheme not in {"http", "https"} or len(parts) != 4 or parts[2] != "pull":
        raise ReviewError(f"Unsupported PR URL: {url}")
    try:
        number = int(parts[3])
    except ValueError as exc:
        raise ReviewError(f"Invalid PR number in URL: {url}") from exc
    return PullRequestRef(
        host=parsed.netloc,
        owner=parts[0],
        repo=parts[1],
        number=number,
        url=url,
    )


def derive_github_api_base(host: str, env: dict[str, str]) -> str:
    override = env.get("GITHUB_API_BASE_URL", "").strip()
    if override:
        return override.rstrip("/")
    if host.lower() == "github.com":
        return "https://api.github.com"
    return f"https://{host}/api/v3"


def _read_json(url: str, headers: dict[str, str]) -> Any:
    req = request.Request(url, headers=headers)
    try:
        with request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise ReviewError(f"HTTP {exc.code} for {url}: {body[:300]}") from exc
    except error.URLError as exc:
        raise ReviewError(f"Network error for {url}: {exc.reason}") from exc


def _basic_auth_value(username: str, secret: str) -> str:
    encoded = base64.b64encode(f"{username}:{secret}".encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def _github_headers(env: dict[str, str]) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "pr-jira-review-skill",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    username = env.get("GITHUB_USERNAME", "").strip()
    token = env.get("GITHUB_TOKEN", "").strip()
    if username and token:
        headers["Authorization"] = _basic_auth_value(username, token)
    elif username or token:
        raise ReviewError("GitHub Basic Auth requires both GITHUB_USERNAME and GITHUB_TOKEN.")
    return headers


def _jira_headers(env: dict[str, str]) -> dict[str, str]:
    username = env.get("JIRA_USERNAME", "").strip()
    password = env.get("JIRA_PASSWORD", "").strip()
    if not username or not password:
        raise ReviewError("Live mode requires JIRA_USERNAME and JIRA_PASSWORD.")
    return {
        "Accept": "application/json",
        "Authorization": _basic_auth_value(username, password),
        "User-Agent": "pr-jira-review-skill",
    }


def fetch_github_bundle(pr_ref: PullRequestRef, env: dict[str, str]) -> dict[str, Any]:
    base = derive_github_api_base(pr_ref.host, env)
    repo_path = f"/repos/{pr_ref.owner}/{pr_ref.repo}"
    pr_path = f"{repo_path}/pulls/{pr_ref.number}"
    issue_path = f"{repo_path}/issues/{pr_ref.number}"
    headers = _github_headers(env)
    return {
        "pr_url": pr_ref.url,
        "pull": _read_json(f"{base}{pr_path}", headers),
        "files": _read_json(f"{base}{pr_path}/files?per_page=100", headers),
        "commits": _read_json(f"{base}{pr_path}/commits?per_page=100", headers),
        "issue_comments": _read_json(f"{base}{issue_path}/comments?per_page=100", headers),
        "review_comments": _read_json(f"{base}{pr_path}/comments?per_page=100", headers),
    }


def extract_jira_keys(bundle: dict[str, Any]) -> list[str]:
    pull = bundle.get("pull", {})
    texts = [
        pull.get("title", ""),
        pull.get("body", ""),
        pull.get("head", {}).get("ref", ""),
    ]
    texts.extend(commit.get("commit", {}).get("message", "") for commit in bundle.get("commits", []))
    keys = []
    seen = set()
    for text in texts:
        for key in JIRA_KEY_RE.findall(text or ""):
            if key not in seen:
                seen.add(key)
                keys.append(key)
    return keys


def _flatten_adf(node: Any) -> str:
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "\n".join(part for part in (_flatten_adf(item) for item in node) if part).strip()
    if not isinstance(node, dict):
        return str(node)

    node_type = node.get("type")
    if node_type == "text":
        return node.get("text", "")

    content = node.get("content", [])
    text = "\n".join(part for part in (_flatten_adf(item) for item in content) if part).strip()
    if node_type in {"paragraph", "heading", "listItem"}:
        return text
    if node_type in {"bulletList", "orderedList"}:
        return "\n".join(f"- {line}" for line in text.splitlines() if line).strip()
    return text


def _extract_acceptance_criteria(fields: dict[str, Any], env: dict[str, str]) -> str | None:
    configured = [item.strip() for item in env.get("JIRA_ACCEPTANCE_FIELD_IDS", "").split(",") if item.strip()]
    for field_id in configured:
        value = fields.get(field_id)
        if value:
            return _flatten_adf(value)

    for key, value in fields.items():
        lower = key.lower()
        if "acceptance" in lower or "criteria" in lower:
            text = _flatten_adf(value)
            if text:
                return text

    description_text = _flatten_adf(fields.get("description"))
    marker = re.search(r"acceptance criteria[:\s]+(.+)", description_text, re.IGNORECASE | re.DOTALL)
    if marker:
        return marker.group(1).strip()
    return None


def fetch_jira_issues(keys: list[str], env: dict[str, str]) -> dict[str, Any]:
    base = env.get("JIRA_BASE_URL", "").strip().rstrip("/")
    if not base:
        raise ReviewError("Live mode requires JIRA_BASE_URL.")
    headers = _jira_headers(env)
    issues = {}
    for key in keys:
        url = f"{base}/rest/api/2/issue/{parse.quote(key)}"
        issues[key] = _read_json(url, headers)
    return issues


def load_mock_bundle(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _tokenize(text: str) -> set[str]:
    return {
        token
        for token in re.findall(r"[a-z0-9]+", (text or "").lower())
        if len(token) > 2 and token not in STOPWORDS and not token.isdigit()
    }


def _is_test_file(path: str) -> bool:
    return bool(TEST_PATH_RE.search(path.replace("\\", "/")))


def _is_doc_file(path: str) -> bool:
    return Path(path).suffix.lower() in DOC_EXTENSIONS or path.lower().startswith(("docs/", "doc/"))


def _is_code_file(path: str) -> bool:
    return not _is_doc_file(path)


def _comment_excerpt(comments: list[dict[str, Any]]) -> list[str]:
    excerpts = []
    for comment in comments[:3]:
        author = comment.get("user", {}).get("login", "unknown")
        body = re.sub(r"\s+", " ", comment.get("body", "")).strip()
        if body:
            excerpts.append(f"{author}: {body[:140]}")
    return excerpts


def _summarize_jira_issue(issue: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    fields = issue.get("fields", {})
    return {
        "key": issue.get("key", "UNKNOWN"),
        "summary": fields.get("summary", "No summary"),
        "status": fields.get("status", {}).get("name", "Unknown"),
        "priority": fields.get("priority", {}).get("name", "Unknown"),
        "assignee": fields.get("assignee", {}).get("displayName", "Unassigned"),
        "description_text": _flatten_adf(fields.get("description")),
        "acceptance_criteria": _extract_acceptance_criteria(fields, env),
    }


def analyze_bundle(bundle: dict[str, Any], env: dict[str, str], mode_used: str, prompt_text: str | None = None) -> dict[str, Any]:
    pull = bundle.get("pull", {})
    files = bundle.get("files", [])
    commits = bundle.get("commits", [])
    jira_keys = extract_jira_keys(bundle)

    jira_raw = bundle.get("jira_issues", {})
    jira_issues = [_summarize_jira_issue(jira_raw[key], env) for key in jira_keys if key in jira_raw]

    code_files = [item for item in files if _is_code_file(item.get("filename", ""))]
    test_files = [item for item in files if _is_test_file(item.get("filename", ""))]
    doc_files = [item for item in files if _is_doc_file(item.get("filename", ""))]
    risky_paths = [
        item.get("filename", "")
        for item in files
        if any(hint in item.get("filename", "").lower() for hint in HIGH_RISK_PATH_HINTS)
    ]
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
        jira_tokens = _tokenize(issue["summary"]) | _tokenize(issue["description_text"])
        overlap = title_tokens & jira_tokens
        if len(overlap) < 2:
            alignment_findings.append(f"{issue['key']} has weak term overlap with the PR title; verify the implementation scope manually.")
        if not issue.get("acceptance_criteria"):
            alignment_findings.append(f"{issue['key']} does not expose acceptance criteria in the configured fields or description.")

    positives = []
    if jira_keys:
        positives.append(f"Detected Jira link(s): {', '.join(jira_keys)}.")
    if test_files:
        positives.append(f"Test files changed: {', '.join(item['filename'] for item in test_files[:3])}.")
    if doc_files:
        positives.append(f"Documentation/runbook updates present: {', '.join(item['filename'] for item in doc_files[:2])}.")

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
    if not risk_findings:
        risk_findings.append("No obvious high-risk paths or unusually large churn were detected.")

    test_findings = []
    if code_files and not test_files:
        test_findings.append("Code changed without any matching test file updates.")
    elif test_files:
        test_findings.append(f"Observed {len(test_files)} test file change(s) alongside the implementation.")
    else:
        test_findings.append("No executable code changes were detected.")

    if risky_paths and not test_files:
        test_findings.append("Add targeted regression coverage for the risky paths before merge.")

    open_questions = []
    open_questions.extend(_comment_excerpt(bundle.get("review_comments", [])))
    open_questions.extend(_comment_excerpt(bundle.get("issue_comments", [])))
    if not open_questions:
        open_questions.append("No reviewer or issue comments were captured.")

    recommendation = "Approve with normal review"
    if not jira_keys or (risk_level == "High" and not test_files):
        recommendation = "Request changes"
    elif risk_level == "High" or alignment_findings or risk_level == "Medium":
        recommendation = "Needs clarification"

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
        },
        "jira_keys": jira_keys,
        "jira_issues": jira_issues,
        "analysis": {
            "positives": positives or ["No positive signals were detected automatically."],
            "alignment_findings": alignment_findings or ["No obvious Jira alignment gaps were detected from the available metadata."],
            "risk_level": risk_level,
            "risk_findings": risk_findings,
            "test_findings": test_findings,
            "open_questions": open_questions[:5],
            "recommendation": recommendation,
        },
    }


def render_markdown(report: dict[str, Any]) -> str:
    pull = report["pull"]
    analysis = report["analysis"]
    jira_lines = []
    if report["jira_issues"]:
        for issue in report["jira_issues"]:
            jira_lines.append(f"- `{issue['key']}`: {issue['summary']} ({issue['status']}, {issue['priority']}, assignee: {issue['assignee']})")
            acceptance = issue.get("acceptance_criteria") or "No acceptance criteria found."
            jira_lines.append(f"  Acceptance criteria: {acceptance}")
    else:
        jira_lines.append("- No Jira issue details were loaded.")

    sections = [
        "# PR Review",
        "",
        "## Review Scope",
        f"- PR: {report['pr_url']}",
        f"- Mode: {report['mode_used']}",
        f"- Generated at: {report['generated_at']}",
    ]
    if report.get("prompt_text"):
        sections.append(f"- Request: {report['prompt_text']}")

    sections.extend(
        [
            "",
            "## PR Summary",
            f"- Title: {pull['title']}",
            f"- Author: {pull['author']}",
            f"- State: {pull['state']}{' (draft)' if pull['draft'] else ''}",
            f"- Branches: `{pull['head_ref']}` -> `{pull['base_ref']}`",
            f"- Size: {pull['changed_files']} files, +{pull['additions']} / -{pull['deletions']} ({pull['churn']} lines)",
            f"- Commits: {pull['commit_count']}",
            f"- Sample files: {', '.join(pull['sample_files']) if pull['sample_files'] else 'None'}",
            "",
            "## Jira Context",
            *jira_lines,
            "",
            "## Jira Alignment",
            *[f"- {item}" for item in analysis["alignment_findings"]],
            "",
            "## Risk Assessment",
            f"- Overall risk: {analysis['risk_level']}",
            *[f"- {item}" for item in analysis["risk_findings"]],
            "",
            "## Test Assessment",
            *[f"- {item}" for item in analysis["test_findings"]],
            "",
            "## Reviewer Questions",
            *[f"- {item}" for item in analysis["open_questions"]],
            "",
            "## Recommendation",
            f"- {analysis['recommendation']}",
            "",
            "## Positive Signals",
            *[f"- {item}" for item in analysis["positives"]],
        ]
    )
    return "\n".join(sections).strip() + "\n"


def build_review(
    *,
    pr_url: str | None,
    prompt_text: str | None,
    mode: str,
    env: dict[str, str] | None = None,
    mock_data_path: str | Path | None = None,
) -> tuple[dict[str, Any], str]:
    env = dict(os.environ if env is None else env)
    resolved_url = pr_url or extract_pr_url(prompt_text or "")
    if not resolved_url and mode != "mock":
        raise ReviewError("No PR URL found. Provide --pr-url or include a PR URL in --prompt-text.")

    if mock_data_path is None:
        mock_data_path = Path(__file__).resolve().parent.parent / "assets" / "mock" / "default-review-bundle.json"

    if mode == "mock":
        bundle = load_mock_bundle(mock_data_path)
        report = analyze_bundle(bundle, env, "mock", prompt_text=prompt_text)
        return report, render_markdown(report)

    try:
        pr_ref = parse_pr_url(resolved_url or "")
        bundle = fetch_github_bundle(pr_ref, env)
        jira_keys = extract_jira_keys(bundle)
        if jira_keys:
            bundle["jira_issues"] = fetch_jira_issues(jira_keys, env)
        report = analyze_bundle(bundle, env, "real", prompt_text=prompt_text)
        return report, render_markdown(report)
    except ReviewError:
        if mode != "auto":
            raise

    bundle = load_mock_bundle(mock_data_path)
    report = analyze_bundle(bundle, env, "mock-fallback", prompt_text=prompt_text)
    return report, render_markdown(report)
