###############Shell script for migrating all repo's reading from file################
#!/bin/bash

name_of_github_org="Four-Agency"
TEAM="CTU"

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

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Install with: brew install jq" >&2
  exit 1
fi

# Read JSON file and process each repository
jq -c '.[]' bitbucket_repos.json | while IFS="" read -r repo_json
do
  clone_url=$(echo "$repo_json" | jq -r '.clone_url')
  project_name=$(echo "$repo_json" | jq -r '.project_name')
  repository_name=$(echo "$repo_json" | jq -r '.repository_name')

  echo "Processing: $repository_name"
  echo "  Clone URL: $clone_url"
  echo "  Project: $project_name"

  git clone --mirror "$clone_url"
  repo=$(echo "$clone_url" | cut -d'/' -f2)

  echo "Local repo created: $repo"

  cd "${repo}"

  gh_repo=$(echo "$repo" | cut -d'.' -f1)

  # Sanitize project name for GitHub topic
  topic=$(sanitize_topic "$project_name")

  # Create GitHub repo
  gh repo create "${name_of_github_org}/${gh_repo}" --private --team "$TEAM"

  # Add topic if it's not empty or "uncategorized"
  if [[ -n "$topic" && "$topic" != "uncategorized" ]]; then
    echo "  Adding topic: $topic"
    gh repo edit "${name_of_github_org}/${gh_repo}" --add-topic "$topic"
  fi

  ##comment above and use below if no team needs to be assigned for GitHub repo
  ##gh repo create ${name_of_github_org}/${gh_repo} --private
  ##gh repo edit ${name_of_github_org}/${gh_repo} --add-topic "$topic"

  git remote set-url origin "git@github.com:${name_of_github_org}/${gh_repo}"

  git remote add bitbucket "$clone_url"
  git push origin --mirror

  cd ..
done
