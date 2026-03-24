from __future__ import annotations

import os
from pathlib import Path

from .common import MANAGED_COMMENT_MARKER, ReviewError, default_mock_data_path, extract_pr_url, load_json, parse_pr_url
from .github_context import fetch_github_bundle
from .jira_context import extract_jira_keys, fetch_jira_issues
from .review_analysis import analyze_bundle, combine_bundles, decide_subagent_plan
from .review_render import render_markdown, write_review_draft


def build_review(
    *,
    pr_url: str | None,
    prompt_text: str | None,
    mode: str,
    env: dict[str, str] | None = None,
    mock_data_path: str | Path | None = None,
    draft_path: str | Path | None = None,
) -> tuple[dict, str]:
    env = dict(os.environ if env is None else env)
    resolved_url = pr_url or extract_pr_url(prompt_text or "")
    mock_path = Path(mock_data_path or default_mock_data_path())
    if not resolved_url and mode != "mock":
        raise ReviewError("No PR URL found. Provide --pr-url or include a PR URL in --prompt-text.")

    if mode == "mock":
        combined_bundle = load_json(mock_path)
        mode_used = "mock"
    else:
        try:
            pr_ref = parse_pr_url(resolved_url or "")
            github_bundle = fetch_github_bundle(pr_ref, env)
            jira_keys = extract_jira_keys(github_bundle)
            jira_issues = fetch_jira_issues(jira_keys, env) if jira_keys else {}
            combined_bundle = combine_bundles(github_bundle, {"jira_keys": jira_keys, "jira_issues": jira_issues})
            mode_used = "real"
        except ReviewError:
            if mode != "auto":
                raise
            combined_bundle = load_json(mock_path)
            mode_used = "mock-fallback"

    report = analyze_bundle(combined_bundle, env, mode_used, prompt_text=prompt_text)
    report["orchestration"] = decide_subagent_plan(
        requested_mode=mode,
        mode_used=mode_used,
        prompt_text=prompt_text,
        pull=report["pull"],
        jira_keys=report["jira_keys"],
    )
    report["publish_target"] = {
        "pr_url": report["pr_url"],
        "managed_marker": MANAGED_COMMENT_MARKER,
    }
    markdown = render_markdown(report)
    if draft_path is not None:
        report["draft"] = write_review_draft(markdown, pr_url=report["pr_url"], source_mode=mode_used, draft_path=draft_path)
    return report, markdown
