from __future__ import annotations

import base64
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SHARED_CORE_DIR = Path(__file__).resolve().parents[3] / "shared-review-core"
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_lib import (
    ReviewError,
    _github_headers,
    _jira_headers,
    analyze_bundle,
    build_review,
    extract_jira_keys,
    extract_pr_url,
    load_mock_bundle,
    parse_pr_url,
)
from review_core.common import MANAGED_COMMENT_MARKER
from review_core.github_context import build_github_context
from review_core.jira_context import build_jira_context
from review_core.publish_comment import publish_review_comment
from review_core.review_analysis import decide_subagent_plan
from review_core.review_render import derive_default_draft_path, render_markdown


class ReviewLibTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mock_path = SCRIPT_DIR.parent / "assets" / "mock" / "default-review-bundle.json"
        self.pr_url = "https://github.com/acme/payments-service/pull/123"

    def test_extract_pr_url_from_prompt(self) -> None:
        prompt = f"Review this PR: {self.pr_url} and focus on risk."
        self.assertEqual(extract_pr_url(prompt), self.pr_url)

    def test_parse_pr_url(self) -> None:
        ref = parse_pr_url(self.pr_url)
        self.assertEqual(ref.host, "github.com")
        self.assertEqual(ref.owner, "acme")
        self.assertEqual(ref.repo, "payments-service")
        self.assertEqual(ref.number, 123)

    def test_extract_jira_keys_from_mock_bundle(self) -> None:
        bundle = load_mock_bundle(self.mock_path)
        self.assertEqual(extract_jira_keys(bundle), ["PAY-248"])

    def test_build_mock_review_returns_context_and_draft(self) -> None:
        draft_path = Path.cwd() / "test-output" / "pr-123-review.md"
        draft_path.parent.mkdir(parents=True, exist_ok=True)
        if draft_path.exists():
            draft_path.unlink()
        report, markdown = build_review(
            pr_url=None,
            prompt_text=f"Review this PR: {self.pr_url}",
            mode="mock",
            mock_data_path=self.mock_path,
            draft_path=draft_path,
        )
        self.assertEqual(report["mode_used"], "mock")
        self.assertIn("## Findings Summary", markdown)
        self.assertIn("## Detailed Analysis And Suggested Fixes", markdown)
        self.assertIn("## Evidence Sources", markdown)
        self.assertIn("draft", report)
        self.assertTrue(Path(report["draft"]["draft_path"]).exists())
        self.assertEqual(report["publish_target"]["managed_marker"], MANAGED_COMMENT_MARKER)

    def test_analyze_bundle_exposes_comments_commit_messages_and_findings(self) -> None:
        bundle = load_mock_bundle(self.mock_path)
        report = analyze_bundle(bundle, {}, "mock")
        self.assertTrue(report["evidence"]["commit_messages"])
        self.assertTrue(report["evidence"]["review_comments"] or report["evidence"]["issue_comments"])
        self.assertTrue(any("patch excerpts" in item.lower() for item in report["analysis"]["code_evidence"]))
        self.assertTrue(any("mutable default" in item.lower() for item in report["analysis"]["code_findings"]))
        self.assertTrue(report["analysis"]["findings_summary"])
        self.assertTrue(all(item["suggested_fix"] for item in report["analysis"]["detailed_findings"]))
        self.assertIn("pr", report["evidence"]["sources"])
        self.assertIn("jira", report["evidence"]["sources"])
        self.assertIn("files", report["evidence"]["sources"])
        markdown = render_markdown(report)
        self.assertIn("# PR Review", markdown)
        self.assertIn("## Findings Summary", markdown)
        self.assertIn("## Detailed Analysis And Suggested Fixes", markdown)
        self.assertIn("## Evidence Sources", markdown)
        self.assertIn("## Recommendation", markdown)


    def test_findings_summary_is_sorted_by_severity(self) -> None:
        bundle = load_mock_bundle(self.mock_path)
        report = analyze_bundle(bundle, {}, "mock")
        order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
        severities = [order[item["severity"]] for item in report["analysis"]["findings_summary"]]
        self.assertEqual(severities, sorted(severities))
    def test_github_context_mock_contract_fields(self) -> None:
        bundle, mode_used = build_github_context(
            pr_url=self.pr_url,
            prompt_text=None,
            mode="mock",
            mock_data_path=self.mock_path,
        )
        self.assertEqual(mode_used, "mock")
        self.assertIn("pull", bundle)
        self.assertIn("files", bundle)
        self.assertNotIn("jira_issues", bundle)

    def test_jira_context_mock_contract_fields(self) -> None:
        github_bundle = load_mock_bundle(self.mock_path)
        jira_bundle, mode_used = build_jira_context(github_bundle, mode="mock", mock_data_path=self.mock_path)
        self.assertEqual(mode_used, "mock")
        self.assertEqual(jira_bundle["jira_keys"], ["PAY-248"])
        self.assertIn("PAY-248", jira_bundle["jira_issues"])
    def test_default_draft_path_includes_owner_repo_and_pr_number(self) -> None:
        draft_path = derive_default_draft_path(self.pr_url)
        self.assertEqual(draft_path.name, "acme-payments-service-pr-123-review.md")

    def test_subagent_plan_stays_local_for_simple_mock_review(self) -> None:
        plan = decide_subagent_plan(
            requested_mode="mock",
            mode_used="mock",
            prompt_text="Review this PR",
            pull={"changed_files": 7, "churn": 260},
            jira_keys=["PAY-248"],
        )
        self.assertFalse(plan["use_subagents"])
        self.assertFalse(plan["agents"])

    def test_subagent_plan_enables_parallel_path_when_requested(self) -> None:
        plan = decide_subagent_plan(
            requested_mode="auto",
            mode_used="real",
            prompt_text="Use subagent parallel review on this PR",
            pull={"changed_files": 20, "churn": 900},
            jira_keys=["PAY-248", "OPS-9"],
        )
        self.assertTrue(plan["use_subagents"])
        self.assertEqual([agent["role"] for agent in plan["agents"]], [
            "GitHub Context Worker",
            "Jira Context Worker",
            "Review Analysis Worker",
        ])

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

    def test_publish_review_comment_creates_managed_comment(self) -> None:
        with mock.patch("review_core.publish_comment.find_managed_issue_comment", return_value=None), mock.patch(
            "review_core.publish_comment.create_issue_comment",
            return_value={"id": 321, "html_url": f"{self.pr_url}#issuecomment-321"},
        ) as create_comment:
            result = publish_review_comment(pr_url=self.pr_url, body="# PR Review", mode="real", env={})
        self.assertEqual(result["action"], "created")
        self.assertFalse(result["marker_found"])
        self.assertIn(MANAGED_COMMENT_MARKER, create_comment.call_args.args[2])

    def test_publish_review_comment_updates_existing_managed_comment(self) -> None:
        existing = {"id": 12, "html_url": f"{self.pr_url}#issuecomment-12", "body": MANAGED_COMMENT_MARKER}
        with mock.patch("review_core.publish_comment.find_managed_issue_comment", return_value=existing), mock.patch(
            "review_core.publish_comment.update_issue_comment",
            return_value={"id": 12, "html_url": f"{self.pr_url}#issuecomment-12"},
        ) as update_comment:
            result = publish_review_comment(pr_url=self.pr_url, body="# PR Review", mode="real", env={})
        self.assertEqual(result["action"], "updated")
        self.assertTrue(result["marker_found"])
        self.assertIn(MANAGED_COMMENT_MARKER, update_comment.call_args.args[3])

    def test_publish_review_comment_rejects_empty_body(self) -> None:
        with self.assertRaises(ReviewError):
            publish_review_comment(pr_url=self.pr_url, body="   ", mode="mock")


if __name__ == "__main__":
    unittest.main()




