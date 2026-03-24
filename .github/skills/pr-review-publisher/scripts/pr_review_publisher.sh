#!/usr/bin/env bash
set -euo pipefail

pr_url=""
input_path=""
mode="real"
managed_marker='<!-- pr-review-report:managed -->'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url)
      pr_url="${2:-}"
      shift 2
      ;;
    --input)
      input_path="${2:-}"
      shift 2
      ;;
    --mode)
      mode="${2:-real}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$pr_url" ]]; then
  echo "error: Provide --pr-url with the pull request URL." >&2
  exit 1
fi
if [[ -z "$input_path" ]]; then
  echo "error: Provide --input with the Markdown draft path." >&2
  exit 1
fi
if [[ ! -f "$input_path" ]]; then
  echo "error: draft file not found: $input_path" >&2
  exit 1
fi

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

github_curl() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local -a args
  args=(-fsSL -X "$method" -H "Accept: application/vnd.github+json" -H "User-Agent: pr-review-publisher-skill" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}" "$url"
}

markdown="$(cat "$input_path")"
trimmed_markdown="$(printf '%s' "$markdown" | node -e "const fs = require('fs'); process.stdout.write(fs.readFileSync(0, 'utf8').trim())")"
if [[ -z "$trimmed_markdown" ]]; then
  echo "error: Review draft is empty." >&2
  exit 1
fi
if [[ ${#trimmed_markdown} -gt 65000 ]]; then
  echo "error: Review draft exceeds the GitHub issue comment size limit." >&2
  exit 1
fi
managed_body="$managed_marker

$trimmed_markdown
"

if [[ "$mode" == "mock" ]]; then
  node -e "process.stdout.write(JSON.stringify({comment_id:999999,comment_url:process.argv[1] + '#issuecomment-mock',action:'created',marker_found:false,pr_url:process.argv[1]}, null, 2))" "$pr_url"
  exit 0
fi

if ! pr_ref="$(parse_pr_url "$pr_url")"; then
  echo "error: Unsupported PR URL: $pr_url" >&2
  exit 1
fi
IFS=$'\t' read -r host owner repo number url <<<"$pr_ref"
base="$(github_api_base "$host")"
comments="$(github_curl GET "$base/repos/$owner/$repo/issues/$number/comments?per_page=100")"
existing="$(node - "$managed_marker" <<'NODE' <<<"$comments"
const fs = require('fs');
const marker = process.argv[2];
const comments = JSON.parse(fs.readFileSync(0, 'utf8'));
const existing = [...comments].reverse().find((comment) => String(comment.body || '').includes(marker));
process.stdout.write(JSON.stringify(existing || null));
NODE
)"
if [[ "$existing" != "null" ]]; then
  comment_id="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).id))" "$existing")"
  updated="$(github_curl PATCH "$base/repos/$owner/$repo/issues/comments/$comment_id" "$(node -e "process.stdout.write(JSON.stringify({ body: process.argv[1] }))" "$managed_body")")"
  node - "$pr_url" "$updated" <<'NODE'
const prUrl = process.argv[2];
const updated = JSON.parse(process.argv[3]);
process.stdout.write(JSON.stringify({
  comment_id: updated.id ?? null,
  comment_url: updated.html_url ?? null,
  action: 'updated',
  marker_found: true,
  pr_url: prUrl,
}, null, 2));
NODE
else
  created="$(github_curl POST "$base/repos/$owner/$repo/issues/$number/comments" "$(node -e "process.stdout.write(JSON.stringify({ body: process.argv[1] }))" "$managed_body")")"
  node - "$pr_url" "$created" <<'NODE'
const prUrl = process.argv[2];
const created = JSON.parse(process.argv[3]);
process.stdout.write(JSON.stringify({
  comment_id: created.id ?? null,
  comment_url: created.html_url ?? null,
  action: 'created',
  marker_found: false,
  pr_url: prUrl,
}, null, 2));
NODE
fi
