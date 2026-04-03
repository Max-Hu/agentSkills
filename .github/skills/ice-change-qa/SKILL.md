---
name: ice-change-qa
description: Load one or more ICE change IDs or change URLs into a reusable session set, fetch change data through the ICE REST API, and answer follow-up QA from that change context. Use when the user provides ICE change IDs, pastes ICE change URLs, wants to keep adding changes during the current session, wants to refresh or replace the active change set, or explicitly asks for update history grounded in ICE change updates.
---

# ICE Change QA

Use this skill when ICE change records are the source of truth for the current session.

This skill keeps a local session manifest plus per-change cache files so later turns can reuse previously loaded change data without re-fetching it unless the user asks for a refresh.

These scripts target Windows PowerShell 5.1 compatibility first and continue to work in PowerShell 7.
Run the entrypoint directly from the current PowerShell host:

```powershell
& .\.github\skills\ice-change-qa\scripts\ice_change_context.ps1 -Ids "9001","CHG-ALPHA-7" -MergeMode append -Mode real
```

If you explicitly want update history from the script entrypoint, add `-IncludeUpdates`:

```powershell
& .\.github\skills\ice-change-qa\scripts\ice_change_context.ps1 -Ids "CHG-ALPHA-7" -IncludeUpdates -Mode real
```

## Core flow

1. Extract zero or more change IDs from `-Ids` or `-PromptText`.
2. Accept either plain IDs or URLs containing `/changes/{id}`.
3. Do not assume IDs are numeric only. Accept IDs such as `9001` and `CHG-ALPHA-7`.
4. Decide whether update enrichment is needed:
   - default: fetch only `v4/changes/{id}`.
   - fetch `v1/changes/{id}/updates` and `v1/apiUsers` only when the user explicitly asks for updates, update history, or who made an update, or when `-IncludeUpdates` is set.
5. Decide state handling:
   - `append` by default when the user adds more change IDs.
   - `replace` when the user explicitly asks to replace or reset the current change set.
   - `-ClearSession` when the user explicitly asks to clear the active ICE change context.
6. Cache the assembled per-change bundle and return a normalized JSON bundle for QA.

## Session rules

- Default merge mode is `append`.
- If the user supplies new IDs, add those changes to the active set unless they explicitly ask to replace it.
- If the user supplies no new IDs but a session manifest already exists, answer from the existing change set.
- If the user asks to refresh without supplying IDs, refresh every change already tracked in the active manifest.
- If the user asks to clear the context, use `-ClearSession`. If no replacement IDs are given, tell the user the active ICE change context is empty.
- Update history is opt-in per request. Cached updates from an earlier request must not be surfaced unless the current request explicitly asks for them.

## Environment

Live mode requires these environment variables:

- `ICE_API_BASE_URL`
- `ICE_USERNAME`
- `ICE_PASSWORD`

`ICE_API_BASE_URL` must point to the shared ICE API root, for example:

```text
https://abc.com/ice/api
```

Use basic authentication with `ICE_USERNAME` and `ICE_PASSWORD`.

## VS Code Chat usage

Use the public skill name in chat and let the skill manage session state.

Typical prompts:

```text
Use $ice-change-qa to load change CHG-ALPHA-7 and summarize the current state.
```

```text
Use $ice-change-qa to load these changes and answer whether they touch the same service:
9001, 9002, CHG-ALPHA-7
```

```text
Use $ice-change-qa to add this change URL to the current ICE change context:
https://abc.com/ice/changes/CHG-ALPHA-7
```

```text
Use $ice-change-qa to load change 9002 and explain the latest updates.
```

```text
Use $ice-change-qa to tell me who updated change 9003 most recently.
```

```text
Use $ice-change-qa to refresh the current ICE change context and answer the same question again.
```

```text
Use $ice-change-qa to replace the current ICE change context with only change CHG-ALPHA-7.
```

```text
Use $ice-change-qa to clear the current ICE change context.
```

## Output bundle

Read these fields from the JSON result:

- `mode_used`
- `session_manifest_path`
- `change_count`
- `changes`
- `combined_change_text`
- `combined_update_text`
- `combined_qa_text`
- `warnings`
- `errors`

Each `changes[]` entry includes:

- `id`
- `change`
- `updates`
- `resolved_updaters`
- `qa_source_text`
- `status`

`updates` and `resolved_updaters` stay empty unless the current request explicitly asks for updates.

## Answering standard

- Ground answers in the loaded ICE change data first.
- Use all fields from each `change` response as the default QA source.
- Use `updates.results` only when the user explicitly asks for updates or update history.
- Treat `resolved_updaters` as a helper for identifying who made an update, not as a separate source of truth.
- If some API calls fail, keep using the available data and call out missing pieces explicitly.
- End answers with the change IDs that support the answer.

## Mock mode

Use `-Mode mock` to validate the skill locally without live ICE access.

The bundled mock dataset lives at [assets/mock/sample-changes.json](./assets/mock/sample-changes.json) and covers:

- first change load without updates
- explicit update enrichment
- append with another change
- manifest reuse
- replace
- refresh against cached changes
- partial success when updates fail
- unresolved updater fallback
- non-numeric ID parsing
