from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, TypedDict


JsonDict = dict[str, Any]


class GitHubBundle(TypedDict, total=False):
    pr_url: str
    pull: JsonDict
    files: list[JsonDict]
    commits: list[JsonDict]
    issue_comments: list[JsonDict]
    review_comments: list[JsonDict]


class JiraBundle(TypedDict, total=False):
    jira_keys: list[str]
    jira_issues: JsonDict


class CombinedBundle(GitHubBundle, JiraBundle, total=False):
    pass


@dataclass(frozen=True)
class PullRequestRef:
    host: str
    owner: str
    repo: str
    number: int
    url: str

    def to_dict(self) -> JsonDict:
        return asdict(self)


@dataclass(frozen=True)
class DraftMetadata:
    draft_path: str
    pr_url: str
    generated_at: str
    source_mode: str

    def to_dict(self) -> JsonDict:
        return asdict(self)


@dataclass(frozen=True)
class PublishResult:
    comment_id: int | None
    comment_url: str | None
    action: str
    marker_found: bool
    pr_url: str

    def to_dict(self) -> JsonDict:
        return asdict(self)
