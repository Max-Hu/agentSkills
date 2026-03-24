from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SHARED_CORE_DIR = Path(__file__).resolve().parents[2] / "shared-review-core"
if str(SHARED_CORE_DIR) not in sys.path:
    sys.path.insert(0, str(SHARED_CORE_DIR))

from review_core.common import ReviewError, load_json
from review_core.review_analysis import analyze_bundle
from review_core.review_render import render_markdown, write_review_draft


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description="Write a review report from a combined PR/Jira bundle.")
    parser.add_argument("--input", required=True, help="Path to a combined bundle JSON file")
    parser.add_argument("--draft-path", help="Optional path for the editable review draft")
    parser.add_argument("--output", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--mode-used", help="Mode label stored in the generated report")
    parser.add_argument("--prompt-text", help="Optional original user request")
    args = parser.parse_args()

    try:
        bundle = load_json(args.input)
        report = analyze_bundle(bundle, {}, args.mode_used or bundle.get("mode_used", "unknown"), prompt_text=args.prompt_text or bundle.get("prompt_text"))
        markdown = render_markdown(report)
        if args.draft_path:
            report["draft"] = write_review_draft(markdown, pr_url=report["pr_url"], source_mode=report["mode_used"], draft_path=args.draft_path)
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

