from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from urllib import parse

from .common import JIRA_KEY_RE, ReviewError, default_mock_data_path, flatten_adf, http_json, jira_headers, load_json, truncate
from .contracts import GitHubBundle, JiraBundle


def extract_jira_keys(bundle: dict[str, Any]) -> list[str]:
    pull = bundle.get("pull", {})
    texts = [pull.get("title", ""), pull.get("body", ""), pull.get("head", {}).get("ref", "")]
    texts.extend(commit.get("commit", {}).get("message", "") for commit in bundle.get("commits", []))
    keys: list[str] = []
    seen: set[str] = set()
    for text in texts:
        for key in JIRA_KEY_RE.findall(text or ""):
            if key not in seen:
                seen.add(key)
                keys.append(key)
    return keys


def fetch_jira_issues(keys: list[str], env: dict[str, str]) -> dict[str, Any]:
    base = env.get("JIRA_BASE_URL", "").strip().rstrip("/")
    if not base:
        raise ReviewError("Live mode requires JIRA_BASE_URL.")
    headers = jira_headers(env)
    issues = {}
    for key in keys:
        issue_url = f"{base}/rest/api/2/issue/{parse.quote(key)}"
        comment_url = f"{base}/rest/api/2/issue/{parse.quote(key)}/comment"
        issue = http_json(issue_url, headers)
        comments = http_json(comment_url, headers).get("comments", [])
        issue["comments"] = comments
        issues[key] = issue
    return issues


def summarize_jira_issue(issue: dict[str, Any]) -> dict[str, Any]:
    fields = issue.get("fields", {})
    description_text = flatten_adf(fields.get("description"))
    comment_entries = issue.get("comments") or fields.get("comment", {}).get("comments", [])
    comment_excerpts = []
    for comment in comment_entries[:6]:
        author = comment.get("user", {}).get("login", comment.get("author", {}).get("displayName", "unknown"))
        body = " ".join(flatten_adf(comment.get("body", "")).split())
        if body:
            comment_excerpts.append(f"{author}: {truncate(body, 160)}")
    return {
        "key": issue.get("key", "UNKNOWN"),
        "title": fields.get("summary", "No summary"),
        "status": fields.get("status", {}).get("name", "Unknown"),
        "priority": fields.get("priority", {}).get("name", "Unknown"),
        "assignee": fields.get("assignee", {}).get("displayName", "Unassigned"),
        "description_text": description_text,
        "comment_excerpts": comment_excerpts,
    }


def load_mock_jira_bundle(path: str | Path | None = None, keys: list[str] | None = None) -> JiraBundle:
    raw = load_json(path or default_mock_data_path()).get("jira_issues", {})
    if keys:
        selected = {key: raw[key] for key in keys if key in raw}
        return {"jira_keys": keys, "jira_issues": selected}
    return {"jira_keys": list(raw.keys()), "jira_issues": raw}


def build_jira_context(
    github_bundle: GitHubBundle,
    *,
    mode: str,
    env: dict[str, str] | None = None,
    mock_data_path: str | Path | None = None,
) -> tuple[JiraBundle, str]:
    env = dict(os.environ if env is None else env)
    keys = extract_jira_keys(github_bundle)
    if mode == "mock":
        return load_mock_jira_bundle(mock_data_path, keys or None), "mock"
    if not keys:
        return {"jira_keys": [], "jira_issues": {}}, "no-jira"
    try:
        return {"jira_keys": keys, "jira_issues": fetch_jira_issues(keys, env)}, "real"
    except ReviewError:
        if mode != "auto":
            raise
    return load_mock_jira_bundle(mock_data_path, keys), "mock-fallback"
