#!/usr/bin/env bash
set -euo pipefail

pr_url=""
prompt_text=""
mode="auto"
mock_data=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url)
      pr_url="${2:-}"
      shift 2
      ;;
    --prompt-text)
      prompt_text="${2:-}"
      shift 2
      ;;
    --mode)
      mode="${2:-auto}"
      shift 2
      ;;
    --mock-data)
      mock_data="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

default_mock_data() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$script_dir/../../pr-jira-review/assets/mock/default-review-bundle.json"
}

extract_pr_url() {
  local text="$1"
  if [[ "$text" =~ https?://[^[:space:]]+/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+ ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
  fi
}

parse_pr_url() {
  local url="$1"
  if [[ ! "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}" \
    "$url"
}

github_api_base() {
  local host="$1"
  if [[ -n "${GITHUB_API_BASE_URL:-}" ]]; then
    printf '%s\n' "${GITHUB_API_BASE_URL%/}"
  elif [[ "${host,,}" == "github.com" ]]; then
    printf '%s\n' "https://api.github.com"
  else
    printf 'https://%s/api/v3\n' "$host"
  fi
}

curl_json() {
  local url="$1"
  local -a args
  args=(-fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: github-pr-context-skill" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${args[@]}" "$url"
}

load_mock_bundle() {
  local path="$1"
  node - "$path" <<'NODE'
const fs = require('fs');
const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
process.stdout.write(JSON.stringify({
  pr_url: raw.pr_url,
  pull: raw.pull || {},
  files: raw.files || [],
  commits: raw.commits || [],
  issue_comments: raw.issue_comments || [],
  review_comments: raw.review_comments || [],
}, null, 2));
NODE
}

fetch_bundle() {
  local pr_ref="$1"
  local host owner repo number url
  IFS=$'\t' read -r host owner repo number url <<<"$pr_ref"
  local base repo_path pr_path issue_path pull files commits issue_comments review_comments
  base="$(github_api_base "$host")"
  repo_path="/repos/$owner/$repo"
  pr_path="$repo_path/pulls/$number"
  issue_path="$repo_path/issues/$number"
  pull="$(curl_json "$base$pr_path")"
  files="$(curl_json "$base$pr_path/files?per_page=100")"
  commits="$(curl_json "$base$pr_path/commits?per_page=100")"
  issue_comments="$(curl_json "$base$issue_path/comments?per_page=100")"
  review_comments="$(curl_json "$base$pr_path/comments?per_page=100")"
  cat <<EOF
{
  "pr_url": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$url"),
  "pull": $pull,
  "files": $files,
  "commits": $commits,
  "issue_comments": $issue_comments,
  "review_comments": $review_comments
}
EOF
}

mock_path="${mock_data:-$(default_mock_data)}"
resolved_url="${pr_url:-$(extract_pr_url "${prompt_text:-}")}"

if [[ -z "$resolved_url" && "$mode" != "mock" ]]; then
  echo "error: No PR URL found. Provide --pr-url or include a PR URL in --prompt-text." >&2
  exit 1
fi

if [[ "$mode" == "mock" ]]; then
  mode_used="mock"
  bundle="$(load_mock_bundle "$mock_path")"
else
  if pr_ref="$(parse_pr_url "$resolved_url")"; then
    if bundle="$(fetch_bundle "$pr_ref")"; then
      mode_used="real"
    elif [[ "$mode" == "auto" ]]; then
      mode_used="mock-fallback"
      bundle="$(load_mock_bundle "$mock_path")"
    else
      echo "error: failed to fetch GitHub context" >&2
      exit 1
    fi
  elif [[ "$mode" == "auto" ]]; then
    mode_used="mock-fallback"
    bundle="$(load_mock_bundle "$mock_path")"
  else
    echo "error: Unsupported PR URL: $resolved_url" >&2
    exit 1
  fi
fi

node - "$mode_used" <<'NODE' <<<"$bundle"
const fs = require('fs');
const modeUsed = process.argv[2];
const bundle = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify({ mode_used: modeUsed, ...bundle }, null, 2));
NODE
