#!/usr/bin/env bash
set -euo pipefail

input_path=""
mode="auto"
mock_data=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      input_path="${2:-}"
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

if [[ -z "$input_path" ]]; then
  echo "error: Provide --input with a GitHub bundle JSON file." >&2
  exit 1
fi

default_mock_data() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$script_dir/../../pr-jira-review/assets/mock/default-review-bundle.json"
}

extract_keys() {
  local path="$1"
  node - "$path" <<'NODE'
const fs = require('fs');
const bundle = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const texts = [];
if (bundle.pull?.title) texts.push(bundle.pull.title);
if (bundle.pull?.body) texts.push(bundle.pull.body);
if (bundle.pull?.head?.ref) texts.push(bundle.pull.head.ref);
for (const commit of bundle.commits || []) {
  if (commit?.commit?.message) texts.push(commit.commit.message);
}
const seen = new Set();
const keys = [];
for (const text of texts) {
  const matches = String(text).match(/\b([A-Z][A-Z0-9]+-\d+)\b/g) || [];
  for (const key of matches) {
    if (!seen.has(key)) {
      seen.add(key);
      keys.push(key);
    }
  }
}
process.stdout.write(JSON.stringify(keys));
NODE
}

load_mock_bundle() {
  local path="$1"
  local keys_json="$2"
  node - "$path" "$keys_json" <<'NODE'
const fs = require('fs');
const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const keys = JSON.parse(process.argv[3]);
const issues = raw.jira_issues || {};
const selected = {};
const selectedKeys = keys.length ? keys : Object.keys(issues);
for (const key of selectedKeys) {
  if (Object.prototype.hasOwnProperty.call(issues, key)) {
    selected[key] = issues[key];
  }
}
process.stdout.write(JSON.stringify({ jira_keys: selectedKeys, jira_issues: selected }, null, 2));
NODE
}

jira_auth_header() {
  if [[ -z "${JIRA_USERNAME:-}" || -z "${JIRA_PASSWORD:-}" ]]; then
    echo "error: Live mode requires JIRA_USERNAME and JIRA_PASSWORD." >&2
    exit 1
  fi
  node -e "process.stdout.write('Basic ' + Buffer.from(process.argv[1], 'utf8').toString('base64'))" "${JIRA_USERNAME}:${JIRA_PASSWORD}"
}

fetch_live_bundle() {
  local keys_json="$1"
  local base="${JIRA_BASE_URL:-}"
  if [[ -z "$base" ]]; then
    echo "error: Live mode requires JIRA_BASE_URL." >&2
    exit 1
  fi
  local auth_header
  auth_header="$(jira_auth_header)"
  node - "$keys_json" "$base" "$auth_header" <<'NODE'
const { execFileSync } = require('child_process');
const keys = JSON.parse(process.argv[2]);
const base = process.argv[3].replace(/\/$/, '');
const auth = process.argv[4];
const request = (url) => JSON.parse(execFileSync('curl', ['-fsSL', '-H', 'Accept: application/json', '-H', `Authorization: ${auth}`, '-H', 'User-Agent: jira-issue-context-skill', url], { encoding: 'utf8' }));
const issues = {};
for (const key of keys) {
  const issue = request(`${base}/rest/api/2/issue/${encodeURIComponent(key)}`);
  const comments = request(`${base}/rest/api/2/issue/${encodeURIComponent(key)}/comment`);
  issue.comments = comments.comments || [];
  issues[key] = issue;
}
process.stdout.write(JSON.stringify({ jira_keys: keys, jira_issues: issues }, null, 2));
NODE
}

mock_path="${mock_data:-$(default_mock_data)}"
keys_json="$(extract_keys "$input_path")"
key_count="$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).length))" "$keys_json")"

if [[ "$mode" == "mock" ]]; then
  mode_used="mock"
  bundle="$(load_mock_bundle "$mock_path" "$keys_json")"
elif [[ "$key_count" == "0" ]]; then
  mode_used="no-jira"
  bundle='{"jira_keys":[],"jira_issues":{}}'
else
  if bundle="$(fetch_live_bundle "$keys_json")"; then
    mode_used="real"
  elif [[ "$mode" == "auto" ]]; then
    mode_used="mock-fallback"
    bundle="$(load_mock_bundle "$mock_path" "$keys_json")"
  else
    echo "error: failed to fetch Jira context" >&2
    exit 1
  fi
fi

node - "$mode_used" <<'NODE' <<<"$bundle"
const fs = require('fs');
const modeUsed = process.argv[2];
const bundle = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify({ mode_used: modeUsed, ...bundle }, null, 2));
NODE
