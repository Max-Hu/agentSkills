from __future__ import annotations

import sys
from pathlib import Path

SHARED_CORE_DIR = Path(__file__).resolve().parents[2] / "shared-review-core"
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_core.common import ReviewError, derive_github_api_base, extract_pr_url, github_headers as _github_headers, jira_headers as _jira_headers, parse_pr_url
from review_core.github_context import fetch_github_bundle, load_mock_bundle
from review_core.jira_context import extract_jira_keys, fetch_jira_issues
from review_core.orchestrator import build_review
from review_core.review_analysis import analyze_bundle
from review_core.review_render import render_markdown

__all__ = [
    "ReviewError",
    "_github_headers",
    "_jira_headers",
    "analyze_bundle",
    "build_review",
    "derive_github_api_base",
    "extract_jira_keys",
    "extract_pr_url",
    "fetch_github_bundle",
    "fetch_jira_issues",
    "load_mock_bundle",
    "parse_pr_url",
    "render_markdown",
]
