from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SHARED_CORE_DIR = Path(__file__).resolve().parents[2] / "shared-review-core"
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_core.common import ReviewError
from review_core.github_context import build_github_context


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch GitHub PR context as JSON.")
    parser.add_argument("--pr-url", help="GitHub pull request URL")
    parser.add_argument("--prompt-text", help="Full user prompt containing the PR URL")
    parser.add_argument("--mode", choices=("auto", "real", "mock"), default="auto")
    parser.add_argument(
        "--mock-data",
        default=str(Path(__file__).resolve().parents[2] / "pr-jira-review" / "assets" / "mock" / "default-review-bundle.json"),
    )
    args = parser.parse_args()

    try:
        bundle, mode_used = build_github_context(
            pr_url=args.pr_url,
            prompt_text=args.prompt_text,
            mode=args.mode,
            mock_data_path=args.mock_data,
        )
    except ReviewError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    payload = {"mode_used": mode_used, **bundle}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
