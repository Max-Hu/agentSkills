from __future__ import annotations

import os
from typing import Any

from .common import MANAGED_COMMENT_MARKER, ReviewError, derive_github_api_base, github_headers, http_json, load_text, parse_pr_url
from .contracts import PublishResult


def render_managed_comment(markdown: str, marker: str = MANAGED_COMMENT_MARKER) -> str:
    body = markdown.strip()
    if not body:
        raise ReviewError("Review draft is empty.")
    if len(body) > 65000:
        raise ReviewError("Review draft exceeds the GitHub issue comment size limit.")
    return f"{marker}\n\n{body}\n"


def list_issue_comments(pr_ref, env: dict[str, str]) -> list[dict[str, Any]]:
    base = derive_github_api_base(pr_ref.host, env)
    headers = github_headers(env)
    url = f"{base}/repos/{pr_ref.owner}/{pr_ref.repo}/issues/{pr_ref.number}/comments?per_page=100"
    return http_json(url, headers)


def create_issue_comment(pr_ref, env: dict[str, str], body: str) -> dict[str, Any]:
    base = derive_github_api_base(pr_ref.host, env)
    headers = github_headers(env)
    url = f"{base}/repos/{pr_ref.owner}/{pr_ref.repo}/issues/{pr_ref.number}/comments"
    return http_json(url, headers, method="POST", payload={"body": body})


def update_issue_comment(pr_ref, env: dict[str, str], comment_id: int, body: str) -> dict[str, Any]:
    base = derive_github_api_base(pr_ref.host, env)
    headers = github_headers(env)
    url = f"{base}/repos/{pr_ref.owner}/{pr_ref.repo}/issues/comments/{comment_id}"
    return http_json(url, headers, method="PATCH", payload={"body": body})


def find_managed_issue_comment(pr_ref, env: dict[str, str], marker: str = MANAGED_COMMENT_MARKER) -> dict[str, Any] | None:
    for comment in reversed(list_issue_comments(pr_ref, env)):
        if marker in comment.get("body", ""):
            return comment
    return None


def publish_review_comment(
    *,
    pr_url: str,
    input_path: str | None = None,
    body: str | None = None,
    mode: str = "real",
    env: dict[str, str] | None = None,
    marker: str = MANAGED_COMMENT_MARKER,
) -> dict[str, Any]:
    env = dict(os.environ if env is None else env)
    markdown = body if body is not None else load_text(input_path or "")
    managed_body = render_managed_comment(markdown, marker)
    if mode == "mock":
        return PublishResult(
            comment_id=999999,
            comment_url=f"{pr_url}#issuecomment-mock",
            action="created",
            marker_found=False,
            pr_url=pr_url,
        ).to_dict()
    pr_ref = parse_pr_url(pr_url)
    existing = find_managed_issue_comment(pr_ref, env, marker)
    if existing:
        updated = update_issue_comment(pr_ref, env, int(existing["id"]), managed_body)
        return PublishResult(
            comment_id=int(updated.get("id", existing["id"])),
            comment_url=updated.get("html_url") or existing.get("html_url"),
            action="updated",
            marker_found=True,
            pr_url=pr_url,
        ).to_dict()
    created = create_issue_comment(pr_ref, env, managed_body)
    return PublishResult(
        comment_id=int(created.get("id")) if created.get("id") is not None else None,
        comment_url=created.get("html_url"),
        action="created",
        marker_found=False,
        pr_url=pr_url,
    ).to_dict()
