from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .common import ReviewError, default_mock_data_path, derive_github_api_base, extract_pr_url, github_headers, http_json, load_json, parse_pr_url
from .contracts import GitHubBundle, PullRequestRef


def _bundle_only(bundle: dict[str, Any]) -> GitHubBundle:
    return {
        "pr_url": bundle.get("pr_url"),
        "pull": bundle.get("pull", {}),
        "files": bundle.get("files", []),
        "commits": bundle.get("commits", []),
        "issue_comments": bundle.get("issue_comments", []),
        "review_comments": bundle.get("review_comments", []),
    }


def fetch_github_bundle(pr_ref: PullRequestRef, env: dict[str, str]) -> GitHubBundle:
    base = derive_github_api_base(pr_ref.host, env)
    repo_path = f"/repos/{pr_ref.owner}/{pr_ref.repo}"
    pr_path = f"{repo_path}/pulls/{pr_ref.number}"
    issue_path = f"{repo_path}/issues/{pr_ref.number}"
    headers = github_headers(env)
    return {
        "pr_url": pr_ref.url,
        "pull": http_json(f"{base}{pr_path}", headers),
        "files": http_json(f"{base}{pr_path}/files?per_page=100", headers),
        "commits": http_json(f"{base}{pr_path}/commits?per_page=100", headers),
        "issue_comments": http_json(f"{base}{issue_path}/comments?per_page=100", headers),
        "review_comments": http_json(f"{base}{pr_path}/comments?per_page=100", headers),
    }


def load_mock_bundle(path: str | Path | None = None) -> GitHubBundle:
    return _bundle_only(load_json(path or default_mock_data_path()))


def build_github_context(
    *,
    pr_url: str | None,
    prompt_text: str | None,
    mode: str,
    env: dict[str, str] | None = None,
    mock_data_path: str | Path | None = None,
) -> tuple[GitHubBundle, str]:
    env = dict(os.environ if env is None else env)
    resolved_url = pr_url or extract_pr_url(prompt_text or "")
    if not resolved_url and mode != "mock":
        raise ReviewError("No PR URL found. Provide --pr-url or include a PR URL in --prompt-text.")
    if mode == "mock":
        return load_mock_bundle(mock_data_path), "mock"
    try:
        pr_ref = parse_pr_url(resolved_url or "")
        return fetch_github_bundle(pr_ref, env), "real"
    except ReviewError:
        if mode != "auto":
            raise
    return load_mock_bundle(mock_data_path), "mock-fallback"
