---
name: confluence-knowledge-qa
description: Load one or more Confluence page links into a reusable session knowledge set and answer follow-up questions from that page content. Use when the user provides Confluence links, wants to keep adding Confluence pages during the current session, wants to refresh or replace the active Confluence context, or needs answers grounded in Confluence documentation fetched through the Confluence REST API.
---

# Confluence Knowledge QA

Use this skill when Confluence pages are the source of truth for the current session.

This skill keeps a local session manifest plus per-page cache files so later turns can reuse previously loaded Confluence pages without re-fetching them unless the user asks for a refresh.

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Run the entrypoint directly from the current PowerShell host:

```powershell
& .\.github\skills\confluence-knowledge-qa\scripts\confluence_context.ps1 -PageUrls "<page-url-1>","<page-url-2>" -MergeMode append -Mode real
```

## Core flow

1. Extract zero or more Confluence page links from `-PageUrls` or `-PromptText`.
2. Decide state handling:
   - `append` by default when the user adds more pages.
   - `replace` when the user explicitly asks to replace or reset the current knowledge set.
   - `-ClearSession` when the user explicitly asks to clear the active Confluence context.
3. Reuse the existing session manifest when no new links are supplied and the user is asking a follow-up question.
4. Re-fetch pages only when they are missing from cache or the user explicitly asks to refresh.
5. Return the normalized JSON bundle and base answers on `combined_content_text`, `combined_sections`, and the per-page metadata.

## Session rules

- Default merge mode is `append`.
- If the user supplies new links, add those pages to the active knowledge set unless they explicitly ask to replace it.
- If the user supplies no new links but a session manifest already exists, answer from the existing knowledge set.
- If the user asks to refresh without supplying links, refresh every page already tracked in the active manifest.
- If the user asks to clear the context, use `-ClearSession`. If no replacement links are given, tell the user the active Confluence context is empty.

## Environment

Live mode requires these environment variables:

- `CONFLUENCE_API_BASE_URL`
- `CONFLUENCE_USERNAME`
- `CONFLUENCE_PASSWORD`

`CONFLUENCE_API_BASE_URL` must be the REST API root, for example:

```text
https://abc.com/confluence/rest/api
```

Use basic authentication with `CONFLUENCE_USERNAME` and `CONFLUENCE_PASSWORD`. For Confluence Cloud, `CONFLUENCE_PASSWORD` can hold an API token.

## VS Code Chat usage

Use the public skill name in chat and let the skill manage session state.

Typical prompts:

```text
Use $confluence-knowledge-qa to load this page and summarize the deployment steps:
https://abc.com/confluence/pages/viewpage.action?pageId=1001
```

```text
Use $confluence-knowledge-qa to load these pages and answer: what changed in the incident process?
https://abc.com/confluence/pages/viewpage.action?pageId=1001
https://abc.com/confluence/display/ENG/Incident+Guide?pageId=1002
```

```text
Use $confluence-knowledge-qa to add this page to the current Confluence context and answer whether it changes the rollback policy:
https://abc.com/confluence/pages/viewpage.action?pageId=1003
```

```text
Use $confluence-knowledge-qa to refresh the current Confluence context and answer the same question again.
```

```text
Use $confluence-knowledge-qa to replace the current Confluence context with this page only:
https://abc.com/confluence/pages/viewpage.action?pageId=1002
```

```text
Use $confluence-knowledge-qa to clear the current Confluence context.
```

## Output bundle

Read these fields from the JSON result:

- `mode_used`
- `session_manifest_path`
- `page_count`
- `pages`
- `combined_content_text`
- `combined_sections`

Each page entry includes:

- `url`
- `id`
- `title`
- `space_key`
- `version`
- `ancestor_titles`
- `content_text`
- `sections`

Each section entry includes:

- `page_id`
- `page_title`
- `heading_path`
- `text`

## Answering standard

- Ground answers in the loaded Confluence pages first.
- If multiple pages disagree, prefer the page with the highest `version` and call out the conflict.
- If you add general knowledge that does not come from Confluence, label it clearly as supplemental reasoning.
- End answers with the page titles and links that support the answer. If a specific section supports a claim, mention its `heading_path`.

## Mock mode

Use `-Mode mock` to validate the skill locally without live Confluence access.

The bundled mock dataset lives at [assets/mock/sample-pages.json](./assets/mock/sample-pages.json) and covers:

- first-page load
- append with another page
- manifest reuse
- replace
- refresh against cached pages
