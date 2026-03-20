from __future__ import annotations

import base64
import unittest
from pathlib import Path

import sys

SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from review_lib import (
    ReviewError,
    _github_headers,
    _jira_headers,
    build_review,
    extract_jira_keys,
    extract_pr_url,
    load_mock_bundle,
    parse_pr_url,
)


class ReviewLibTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mock_path = SCRIPT_DIR.parent / "assets" / "mock" / "default-review-bundle.json"

    def test_extract_pr_url_from_prompt(self) -> None:
        prompt = "Review this PR: https://github.com/org/repo/pull/123 and focus on risk."
        self.assertEqual(extract_pr_url(prompt), "https://github.com/org/repo/pull/123")

    def test_parse_pr_url(self) -> None:
        ref = parse_pr_url("https://github.com/acme/payments-service/pull/123")
        self.assertEqual(ref.host, "github.com")
        self.assertEqual(ref.owner, "acme")
        self.assertEqual(ref.repo, "payments-service")
        self.assertEqual(ref.number, 123)

    def test_extract_jira_keys_from_mock_bundle(self) -> None:
        bundle = load_mock_bundle(self.mock_path)
        self.assertEqual(extract_jira_keys(bundle), ["PAY-248"])

    def test_build_mock_review(self) -> None:
        report, markdown = build_review(
            pr_url=None,
            prompt_text="Review this PR: https://github.com/acme/payments-service/pull/123",
            mode="mock",
            mock_data_path=self.mock_path,
        )
        self.assertEqual(report["mode_used"], "mock")
        self.assertIn("## Jira Context", markdown)
        self.assertIn("PAY-248", markdown)
        self.assertIn("## Recommendation", markdown)

    def test_github_basic_auth_header(self) -> None:
        headers = _github_headers({"GITHUB_USERNAME": "octocat", "GITHUB_TOKEN": "ghp_xxx"})
        expected = base64.b64encode(b"octocat:ghp_xxx").decode("ascii")
        self.assertEqual(headers["Authorization"], f"Basic {expected}")

    def test_jira_basic_auth_header(self) -> None:
        headers = _jira_headers({"JIRA_USERNAME": "jira-user", "JIRA_PASSWORD": "jira-password"})
        expected = base64.b64encode(b"jira-user:jira-password").decode("ascii")
        self.assertEqual(headers["Authorization"], f"Basic {expected}")

    def test_github_basic_auth_requires_both_values(self) -> None:
        with self.assertRaises(ReviewError):
            _github_headers({"GITHUB_USERNAME": "octocat"})


if __name__ == "__main__":
    unittest.main()
