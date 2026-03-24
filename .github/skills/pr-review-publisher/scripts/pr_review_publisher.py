from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SHARED_CORE_DIR = Path(__file__).resolve().parents[2] / "shared-review-core"
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_core.common import ReviewError
from review_core.publish_comment import publish_review_comment


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish or update a managed PR review comment.")
    parser.add_argument("--pr-url", required=True, help="GitHub pull request URL")
    parser.add_argument("--input", required=True, help="Path to a Markdown draft file")
    parser.add_argument("--mode", choices=("real", "mock"), default="real")
    args = parser.parse_args()

    try:
        result = publish_review_comment(pr_url=args.pr_url, input_path=args.input, mode=args.mode)
    except ReviewError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
