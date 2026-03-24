#!/usr/bin/env bash
set -euo pipefail

pr_url=""
prompt_text=""
mode="auto"
mock_data=""
draft_path=""
output="markdown"
managed_marker='<!-- pr-review-report:managed -->'

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
    --draft-path)
      draft_path="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-markdown}"
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
  printf '%s\n' "$script_dir/../assets/mock/default-review-bundle.json"
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

github_curl() {
  local url="$1"
  local -a args
  args=(-fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: pr-jira-review-skill" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${args[@]}" "$url"
}

jira_auth_header() {
  if [[ -z "${JIRA_USERNAME:-}" || -z "${JIRA_PASSWORD:-}" ]]; then
    echo "error: Live mode requires JIRA_USERNAME and JIRA_PASSWORD." >&2
    exit 1
  fi
  node -e "process.stdout.write('Basic ' + Buffer.from(process.argv[1], 'utf8').toString('base64'))" "${JIRA_USERNAME}:${JIRA_PASSWORD}"
}

load_mock_bundle() {
  cat "$1"
}

fetch_live_bundle() {
  local pr_ref="$1"
  local host owner repo number url
  IFS=$'\t' read -r host owner repo number url <<<"$pr_ref"
  local base repo_path pr_path issue_path pull files commits issue_comments review_comments keys_json auth_header jira_issues
  base="$(github_api_base "$host")"
  repo_path="/repos/$owner/$repo"
  pr_path="$repo_path/pulls/$number"
  issue_path="$repo_path/issues/$number"
  pull="$(github_curl "$base$pr_path")"
  files="$(github_curl "$base$pr_path/files?per_page=100")"
  commits="$(github_curl "$base$pr_path/commits?per_page=100")"
  issue_comments="$(github_curl "$base$issue_path/comments?per_page=100")"
  review_comments="$(github_curl "$base$pr_path/comments?per_page=100")"
  keys_json="$(node - <<'NODE' <<<"$pull\n__SPLIT__\n$commits"
const fs = require('fs');
const [pullRaw, commitsRaw] = fs.readFileSync(0, 'utf8').split('\n__SPLIT__\n');
const pull = JSON.parse(pullRaw);
const commits = JSON.parse(commitsRaw);
const texts = [pull.title || '', pull.body || '', pull.head?.ref || '', ...commits.map((commit) => commit?.commit?.message || '')];
const seen = new Set();
const keys = [];
for (const text of texts) {
  for (const key of String(text).match(/\b([A-Z][A-Z0-9]+-\d+)\b/g) || []) {
    if (!seen.has(key)) {
      seen.add(key);
      keys.push(key);
    }
  }
}
process.stdout.write(JSON.stringify(keys));
NODE
)"
  if [[ -n "${JIRA_BASE_URL:-}" && "$keys_json" != "[]" ]]; then
    auth_header="$(jira_auth_header)"
    jira_issues="$(node - "$keys_json" "${JIRA_BASE_URL}" "$auth_header" <<'NODE'
const { execFileSync } = require('child_process');
const keys = JSON.parse(process.argv[2]);
const base = process.argv[3].replace(/\/$/, '');
const auth = process.argv[4];
const request = (url) => JSON.parse(execFileSync('curl', ['-fsSL', '-H', 'Accept: application/json', '-H', `Authorization: ${auth}`, '-H', 'User-Agent: pr-jira-review-skill', url], { encoding: 'utf8' }));
const issues = {};
for (const key of keys) {
  const issue = request(`${base}/rest/api/2/issue/${encodeURIComponent(key)}`);
  const comments = request(`${base}/rest/api/2/issue/${encodeURIComponent(key)}/comment`);
  issue.comments = comments.comments || [];
  issues[key] = issue;
}
process.stdout.write(JSON.stringify(issues));
NODE
)"
  else
    jira_issues='{}'
  fi
  cat <<EOF
{
  "pr_url": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$url"),
  "pull": $pull,
  "files": $files,
  "commits": $commits,
  "issue_comments": $issue_comments,
  "review_comments": $review_comments,
  "jira_keys": $keys_json,
  "jira_issues": $jira_issues
}
EOF
}

orchestration_json() {
  local requested_mode="$1"
  local mode_used="$2"
  local prompt="$3"
  local report_json="$4"
  node - "$requested_mode" "$mode_used" "$prompt" <<'NODE' <<<"$report_json"
const fs = require('fs');
const requestedMode = process.argv[2];
const modeUsed = process.argv[3];
const promptText = process.argv[4] || '';
const report = JSON.parse(fs.readFileSync(0, 'utf8'));
const reasons = [];
if (['real', 'auto'].includes(requestedMode)) reasons.push('Live or live-capable mode benefits from parallel context gathering.');
if (Number(report.pull?.changed_files || 0) > 15 || Number(report.pull?.churn || 0) >= 600) reasons.push('Large PR size crosses the threshold for parallel analysis.');
if ((report.jira_keys || []).length > 1) reasons.push('Multiple Jira keys were detected and can be investigated independently.');
if (/\b(subagent|parallel|deep|depth|thorough)\b/i.test(promptText)) reasons.push('The user explicitly asked for deeper or parallel review behavior.');
const useSubagents = reasons.length > 0 && modeUsed !== 'mock-fallback';
process.stdout.write(JSON.stringify({
  use_subagents: useSubagents,
  requested_mode: requestedMode,
  mode_used: modeUsed,
  reasons: reasons.length ? reasons : ['Run locally in a single thread for this request.'],
  agents: useSubagents ? [
    { name: 'Agent A', role: 'GitHub Context Worker', responsibility: 'Fetch PR metadata, files, commits, and comments.' },
    { name: 'Agent B', role: 'Jira Context Worker', responsibility: 'Extract Jira keys and gather issue context in parallel.' },
    { name: 'Agent C', role: 'Review Analysis Worker', responsibility: 'Analyze the combined evidence once context workers complete.' },
  ] : [],
}, null, 2));
NODE
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
  if pr_ref="$(parse_pr_url "$resolved_url")" && bundle="$(fetch_live_bundle "$pr_ref")"; then
    mode_used="real"
  elif [[ "$mode" == "auto" ]]; then
    mode_used="mock-fallback"
    bundle="$(load_mock_bundle "$mock_path")"
  else
    echo "error: failed to build review bundle" >&2
    exit 1
  fi
fi

temp_bundle="$(mktemp)"
printf '%s' "$bundle" > "$temp_bundle"
writer_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_writer.sh"
json_report="$("$writer_script" --input "$temp_bundle" --output json ${draft_path:+--draft-path "$draft_path"} ${mode_used:+--mode-used "$mode_used"} ${prompt_text:+--prompt-text "$prompt_text"})"
rm -f "$temp_bundle"

orchestration="$(orchestration_json "$mode" "$mode_used" "${prompt_text:-}" "$json_report")"
final_json="$(node - "$managed_marker" "$orchestration" <<'NODE' <<<"$json_report"
const fs = require('fs');
const managedMarker = process.argv[2];
const orchestration = JSON.parse(process.argv[3]);
const report = JSON.parse(fs.readFileSync(0, 'utf8'));
report.orchestration = orchestration;
report.publish_target = { pr_url: report.pr_url, managed_marker: managedMarker };
process.stdout.write(JSON.stringify(report, null, 2));
NODE
)"

if [[ "$output" == "json" ]]; then
  printf '%s\n' "$final_json"
elif [[ -n "$draft_path" && -f "$draft_path" ]]; then
  cat "$draft_path"
else
  temp_bundle="$(mktemp)"
  printf '%s' "$bundle" > "$temp_bundle"
  "$writer_script" --input "$temp_bundle" --output markdown ${mode_used:+--mode-used "$mode_used"} ${prompt_text:+--prompt-text "$prompt_text"}
  rm -f "$temp_bundle"
fi
