# Review Template

The script emits the following fixed Markdown structure:

1. `# PR Review`
2. `## Review Scope`
3. `## PR Summary`
4. `## Jira Context`
5. `## Jira Alignment`
6. `## Risk Assessment`
7. `## Test Assessment`
8. `## Reviewer Questions`
9. `## Recommendation`
10. `## Positive Signals`

Use this structure by default. Keep the emphasis on:

- Whether the PR is traceable to one or more Jira issues
- Whether the implementation appears to satisfy Jira intent and acceptance criteria
- Whether the code change introduces operational, data, or rollout risk
- Whether tests changed in proportion to the code change

If a section has no findings, explicitly say so instead of removing the section.
