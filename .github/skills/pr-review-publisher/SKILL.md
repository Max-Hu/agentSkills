---
name: pr-review-publisher
description: Publish or update a managed GitHub PR issue comment from an editable Markdown review draft. Use when the user wants the generated review report posted back to the PR, wants to update the same managed comment after editing the draft, or wants a dedicated publish-only step after review generation.
---

# PR Review Publisher

Use this skill only for the publish stage.

Run:

```powershell
python .github/skills/pr-review-publisher/scripts/pr_review_publisher.py --pr-url "<pr-url>" --input "<draft.md>" --mode real
```

The publisher maintains one managed PR issue comment marked with a stable HTML comment and updates that comment on later publishes.
