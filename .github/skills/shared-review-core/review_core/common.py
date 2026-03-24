from __future__ import annotations

import base64
import json
import re
from pathlib import Path
from typing import Any
from urllib import error, parse, request

from .contracts import PullRequestRef

PR_URL_RE = re.compile(r"https?://[^\s]+/[^/\s]+/[^/\s]+/pull/\d+")
JIRA_KEY_RE = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")
MANAGED_COMMENT_MARKER = "<!-- pr-review-report:managed -->"


class ReviewError(RuntimeError):
    pass


def default_mock_data_path() -> Path:
    return Path(__file__).resolve().parents[2] / "pr-jira-review" / "assets" / "mock" / "default-review-bundle.json"


def extract_pr_url(text: str) -> str | None:
    match = PR_URL_RE.search(text or "")
    return match.group(0) if match else None


def parse_pr_url(url: str) -> PullRequestRef:
    parsed = parse.urlparse(url)
    parts = [part for part in parsed.path.split("/") if part]
    if parsed.scheme not in {"http", "https"} or len(parts) != 4 or parts[2] != "pull":
        raise ReviewError(f"Unsupported PR URL: {url}")
    try:
        number = int(parts[3])
    except ValueError as exc:
        raise ReviewError(f"Invalid PR number in URL: {url}") from exc
    return PullRequestRef(host=parsed.netloc, owner=parts[0], repo=parts[1], number=number, url=url)


def derive_github_api_base(host: str, env: dict[str, str]) -> str:
    override = env.get("GITHUB_API_BASE_URL", "").strip()
    if override:
        return override.rstrip("/")
    if host.lower() == "github.com":
        return "https://api.github.com"
    return f"https://{host}/api/v3"


def _basic_auth_value(username: str, secret: str) -> str:
    encoded = base64.b64encode(f"{username}:{secret}".encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def github_headers(env: dict[str, str]) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "pr-jira-review-skill",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    username = env.get("GITHUB_USERNAME", "").strip()
    token = env.get("GITHUB_TOKEN", "").strip()
    if username and token:
        headers["Authorization"] = _basic_auth_value(username, token)
    elif username or token:
        raise ReviewError("GitHub Basic Auth requires both GITHUB_USERNAME and GITHUB_TOKEN.")
    return headers


def jira_headers(env: dict[str, str]) -> dict[str, str]:
    username = env.get("JIRA_USERNAME", "").strip()
    password = env.get("JIRA_PASSWORD", "").strip()
    if not username or not password:
        raise ReviewError("Live mode requires JIRA_USERNAME and JIRA_PASSWORD.")
    return {
        "Accept": "application/json",
        "Authorization": _basic_auth_value(username, password),
        "User-Agent": "pr-jira-review-skill",
    }


def http_json(url: str, headers: dict[str, str], *, method: str = "GET", payload: Any | None = None) -> Any:
    request_headers = dict(headers)
    data = None
    if payload is not None:
        request_headers.setdefault("Content-Type", "application/json")
        data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        raise ReviewError(f"HTTP {exc.code} for {url}: {body[:300]}") from exc
    except error.URLError as exc:
        raise ReviewError(f"Network error for {url}: {exc.reason}") from exc


def load_json(path: str | Path) -> Any:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_text(path: str | Path) -> str:
    return Path(path).read_text(encoding="utf-8")


def write_text(path: str | Path, content: str) -> Path:
    resolved = Path(path)
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_text(content, encoding="utf-8")
    return resolved


def flatten_adf(node: Any) -> str:
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "\n".join(part for part in (flatten_adf(item) for item in node) if part).strip()
    if not isinstance(node, dict):
        return str(node)
    node_type = node.get("type")
    if node_type == "text":
        return node.get("text", "")
    content = node.get("content", [])
    text = "\n".join(part for part in (flatten_adf(item) for item in content) if part).strip()
    if node_type in {"paragraph", "heading", "listItem"}:
        return text
    if node_type in {"bulletList", "orderedList"}:
        return "\n".join(f"- {line}" for line in text.splitlines() if line).strip()
    return text


def truncate(text: str, limit: int = 180) -> str:
    clean = re.sub(r"\s+", " ", text or "").strip()
    if len(clean) <= limit:
        return clean
    return clean[: limit - 3].rstrip() + "..."
