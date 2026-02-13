#!/usr/bin/env bash
# Populate bitbucket_repos.json from the Bitbucket API (supports pagination).
# Usage examples:
#   BITBUCKET_USER=you@example.com BITBUCKET_TOKEN=app_token ./populate_bitbucket_repos.sh -w marmelo
#   ./populate_bitbucket_repos.sh -w marmelo -u you@example.com -t app_token -c ssh -o my_repos.json

set -euo pipefail

progname="$(basename "$0")"
WORKSPACE=""
OUTFILE="./bitbucket_repos.json"
CLONE_TYPE="ssh" # or ssh
BITBUCKET_USER="${BITBUCKET_USER:-}"
BITBUCKET_TOKEN="${BITBUCKET_TOKEN:-}"
PAGE_LEN=100

# Sanitize project name to create valid GitHub topic
# GitHub topics must be lowercase, use hyphens instead of spaces,
# only contain a-z, 0-9, and hyphens, and be max 50 characters
sanitize_topic() {
  local topic="$1"
  # Convert to lowercase
  topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]')
  # Replace spaces with hyphens
  topic=$(echo "$topic" | sed 's/ /-/g')
  # Remove invalid characters (keep only a-z, 0-9, -)
  topic=$(echo "$topic" | sed 's/[^a-z0-9-]//g')
  # Replace multiple consecutive hyphens with single hyphen
  topic=$(echo "$topic" | sed 's/-\+/-/g')
  # Truncate to 50 characters
  topic=$(echo "$topic" | cut -c1-50)
  # Remove leading/trailing hyphens
  topic=$(echo "$topic" | sed 's/^-*//;s/-*$//')
  echo "$topic"
}

print_help() {
  cat <<EOF
$progname - Fetch Bitbucket workspace repositories and write clone URLs with project names to a JSON file.

Options:
  -w WORKSPACE     Bitbucket workspace ID or slug (required)
  -u USER          Bitbucket username/email (or set BITBUCKET_USER env var)
  -t TOKEN         Bitbucket app password / API token (or set BITBUCKET_TOKEN env var)
  -c CLONE_TYPE    'https' (default) or 'ssh'
  -o OUTFILE       Output file path (default: ./bitbucket_repos.json)
  -p PAGELEN       page size (default: 100, max depends on API)
  -h               Show this help
EOF
}

while getopts ":w:u:t:c:o:p:h" opt; do
  case $opt in
    w) WORKSPACE="$OPTARG" ;;
    u) BITBUCKET_USER="$OPTARG" ;;
    t) BITBUCKET_TOKEN="$OPTARG" ;;
    c) CLONE_TYPE="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    p) PAGE_LEN="$OPTARG" ;;
    h) print_help; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; print_help; exit 2 ;;
    :) echo "Missing arg for -$OPTARG" >&2; print_help; exit 2 ;;
  esac
done

if [[ -z "$WORKSPACE" ]]; then
  echo "Error: workspace is required (-w)" >&2
  print_help
  exit 2
fi

if [[ -z "${BITBUCKET_USER:-}" || -z "${BITBUCKET_TOKEN:-}" ]]; then
  echo "Error: provide credentials via BITBUCKET_USER and BITBUCKET_TOKEN env vars or -u/-t options" >&2
  exit 2
fi

if [[ "$CLONE_TYPE" != "https" && "$CLONE_TYPE" != "ssh" ]]; then
  echo "Error: -c must be 'https' or 'ssh'" >&2
  exit 2
fi

tmpf="$(mktemp "/tmp/${progname}.XXXXXX.json")"
trap 'rm -f "$tmpf"' EXIT

api_url="https://api.bitbucket.org/2.0/repositories/${WORKSPACE}?pagelen=${PAGE_LEN}"
echo "Fetching repositories for workspace '${WORKSPACE}' (clone type: ${CLONE_TYPE})..."

# Temporary output - collect lines then dedupe/sort
out_tmp="$(mktemp "/tmp/${progname}.out.XXXXXX")"
trap 'rm -f "$tmpf" "$out_tmp"' EXIT

# choose parser: jq preferred
have_jq=0
if command -v jq >/dev/null 2>&1; then
  have_jq=1
fi

while [[ -n "$api_url" ]]; do
  # fetch page
  http_status=$(curl -sS -u "${BITBUCKET_USER}:${BITBUCKET_TOKEN}" -w "%{http_code}" -o "$tmpf" "$api_url")
  if [[ "$http_status" -ge 400 ]]; then
    echo "Error: HTTP $http_status fetching $api_url" >&2
    echo "Response body:" >&2
    sed -n '1,200p' "$tmpf" >&2
    exit 3
  fi

  if [[ $have_jq -eq 1 ]]; then
    # extract clone URLs and project info for this page
    jq -c --arg clone "${CLONE_TYPE}" '.values[] | {
      clone_url: (.links.clone[] | select(.name == $clone) | .href),
      project_name: (.project.name // "uncategorized"),
      repository_name: .name,
      full_name: .full_name
    }' "$tmpf" >> "$out_tmp" || true
    # next page url (if any)
    next_url=$(jq -r '.next // ""' "$tmpf")
  else
    # Python fallback parser (no jq)
    python3 - <<PY >>"$out_tmp"
import json,sys
f = open("$tmpf","r")
j = json.load(f)
for v in j.get("values",[]):
    links = v.get("links",{})
    clone = links.get("clone", [])
    project = v.get("project", {})
    for c in clone:
        if c.get("name") == "$CLONE_TYPE":
            repo_data = {
                "clone_url": c.get("href"),
                "project_name": project.get("name", "uncategorized"),
                "repository_name": v.get("name"),
                "full_name": v.get("full_name")
            }
            print(json.dumps(repo_data))
PY
    # read next from stderr capture by reading last stderr (above wrote to stderr)
    # We capture next in a temporary file instead:
    # (We cannot read easily here; so use jq-less approach: extract 'next' with python separately)
    next_url=$(python3 - <<PY
import json,sys
j=json.load(open("$tmpf"))
print(j.get("next",""))
PY
)
  fi

  if [[ -z "$next_url" ]]; then
    api_url=""
  else
    api_url="$next_url"
  fi
done

# dedupe and clean, then wrap in JSON array
# remove empty lines, dedupe by clone_url, and create valid JSON array
awk '{$1=$1; if(length) print}' "$out_tmp" | sort -u > "${OUTFILE}.tmp"

# Wrap JSON objects in array
echo '[' > "${OUTFILE}.new"
awk '{
  if (NR > 1) print ","
  printf "%s", $0
}' "${OUTFILE}.tmp" >> "${OUTFILE}.new"
echo '' >> "${OUTFILE}.new"
echo ']' >> "${OUTFILE}.new"

rm -f "${OUTFILE}.tmp"
mv "${OUTFILE}.new" "$OUTFILE"

count=$(jq 'length' "$OUTFILE" 2>/dev/null || wc -l < "$OUTFILE" | tr -d ' ')
echo "Wrote ${count} repositories to ${OUTFILE}"
echo "Done."