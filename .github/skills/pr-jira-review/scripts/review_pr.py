from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from review_lib import ReviewError, build_review


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description="Review a GitHub PR against Jira context.")
    parser.add_argument("--pr-url", help="GitHub pull request URL")
    parser.add_argument("--prompt-text", help="Full user prompt containing the PR URL")
    parser.add_argument(
        "--mode",
        choices=("auto", "real", "mock"),
        default="auto",
        help="Use real APIs, bundled mock data, or try real then fall back to mock.",
    )
    parser.add_argument(
        "--mock-data",
        default=str(Path(__file__).resolve().parent.parent / "assets" / "mock" / "default-review-bundle.json"),
        help="Path to a mock bundle JSON file.",
    )
    parser.add_argument(
        "--draft-path",
        help="Optional path for writing an editable Markdown draft.",
    )
    parser.add_argument(
        "--output",
        choices=("markdown", "json"),
        default="markdown",
        help="Render Markdown or emit the structured report as JSON.",
    )
    args = parser.parse_args()

    try:
        report, markdown = build_review(
            pr_url=args.pr_url,
            prompt_text=args.prompt_text,
            mode=args.mode,
            mock_data_path=args.mock_data,
            draft_path=args.draft_path,
        )
    except ReviewError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.output == "json":
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

