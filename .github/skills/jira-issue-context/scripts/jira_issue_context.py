from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SHARED_CORE_DIR = Path(__file__).resolve().parents[2] / "shared-review-core"
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_core.common import ReviewError, load_json
from review_core.jira_context import build_jira_context


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract Jira context for a PR bundle.")
    parser.add_argument("--input", required=True, help="Path to a GitHub bundle JSON file")
    parser.add_argument("--mode", choices=("auto", "real", "mock"), default="auto")
    parser.add_argument(
        "--mock-data",
        default=str(Path(__file__).resolve().parents[2] / "pr-jira-review" / "assets" / "mock" / "default-review-bundle.json"),
    )
    args = parser.parse_args()

    try:
        github_bundle = load_json(args.input)
        jira_bundle, mode_used = build_jira_context(github_bundle, mode=args.mode, mock_data_path=args.mock_data)
    except ReviewError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    payload = {"mode_used": mode_used, **jira_bundle}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
