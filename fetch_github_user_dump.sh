#!/usr/bin/env bash
set -euo pipefail

# Usage:
# GITHUB_TOKEN=... ./fetch_github_user_dump.sh username [commits_per_repo] [repo_limit]
# Example: GITHUB_TOKEN=$GITHUB_TOKEN ./fetch_github_user_dump.sh maryam-123123 5 50

USERNAME="${1:-}"
COMMITS_PER_REPO="${2:-5}"
REPO_LIMIT="${3:-0}"

if [[ -z "$USERNAME" ]]; then
  echo "Usage: $0 username [commits_per_repo] [repo_limit]"
  exit 1
fi

API="https://api.github.com"
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: token $GITHUB_TOKEN")
else
  echo "Warning: no GITHUB_TOKEN set. Unauthenticated requests are rate-limited (60/hr)."
fi

OUTDIR="./github_dump_${USERNAME}_$(date +%Y%m%d%H%M%S)"
mkdir -p "$OUTDIR"
meta_file="$OUTDIR/profile.json"

echo "Fetching profile for $USERNAME..."
curl -s "${AUTH_HEADER[@]}" "$API/users/$USERNAME" | jq '.' > "$meta_file"

echo "Listing repos (including forks & archived)..."
repos_pages_dir="$OUTDIR/_repo_pages"
mkdir -p "$repos_pages_dir"
page=1
per_page=100

total_fetched=0
while :; do
  echo "  fetching page $page..."
  page_resp_file="$repos_pages_dir/repos_page_${page}.json"
  http_resp=$(curl -s -w "%{http_code}" -o "$page_resp_file" "${AUTH_HEADER[@]}" "$API/users/$USERNAME/repos?per_page=$per_page&page=$page")
  if [[ "$http_resp" -ne 200 ]]; then
    if [[ ! -s "$page_resp_file" ]] || [[ "$(jq 'length' "$page_resp_file" 2>/dev/null || echo 0)" -eq 0 ]]; then
      rm -f "$page_resp_file"
      break
    fi
  fi
  page_count=$(jq 'length' "$page_resp_file")
  if [[ "$page_count" -eq 0 ]]; then
    rm -f "$page_resp_file"
    break
  fi
  ((total_fetched+=page_count))
  ((page++))
done

if ls "$repos_pages_dir"/repos_page_*.json >/dev/null 2>&1; then
  jq -s 'add' "$repos_pages_dir"/repos_page_*.json > "$OUTDIR/repos_merged.json"
else
  echo "No repositories found or failed to list repos."
  echo "Check network, username spelling, or rate limits."
  exit 0
fi

rm -rf "$repos_pages_dir"

repos_file="$OUTDIR/repos_merged.json"
total_repos=$(jq 'length' "$repos_file")
echo "Found $total_repos repositories."

if [[ "$REPO_LIMIT" -gt 0 && "$total_repos" -gt "$REPO_LIMIT" ]]; then
  echo "Limiting to first $REPO_LIMIT repos."
fi

i=0
mkdir -p "$OUTDIR/repos"
jq -c '.[]' "$repos_file" | while read -r repo; do
  ((i++))
  if [[ "$REPO_LIMIT" -gt 0 && "$i" -gt "$REPO_LIMIT" ]]; then
    break
  fi

  name=$(echo "$repo" | jq -r '.name')
  full_name=$(echo "$repo" | jq -r '.full_name')
  echo "Processing [$i] $full_name ..."
  repo_dir="$OUTDIR/repos/$name"
  mkdir -p "$repo_dir"

  echo "$repo" | jq '.' > "$repo_dir/metadata.json"

  readme_out="$repo_dir/readme_raw"
  readme_code=$(curl -s -o "$readme_out" -w "%{http_code}" "${AUTH_HEADER[@]}" -H "Accept: application/vnd.github.v3.raw" "$API/repos/$full_name/readme" || echo "000")
  if [[ "$readme_code" == "200" ]]; then
    echo "  saved README to $readme_out"
  else
    rm -f "$readme_out"
  fi

  license_resp=$(curl -s "${AUTH_HEADER[@]}" "$API/repos/$full_name/license" || true)
  if [[ -n "$license_resp" && "$license_resp" != "null" ]]; then
    echo "$license_resp" | jq '.' > "$repo_dir/license.json"
  fi

  default_branch=$(echo "$repo" | jq -r '.default_branch // empty')
  if [[ -n "$default_branch" ]]; then
    branch_info=$(curl -s "${AUTH_HEADER[@]}" "$API/repos/$full_name/branches/$default_branch" || echo "{}")
    echo "$branch_info" | jq '.' > "$repo_dir/branch_${default_branch}.json"
    commit_sha=$(echo "$branch_info" | jq -r '.commit.sha // empty')
    if [[ -n "$commit_sha" ]]; then
      tree_resp=$(curl -s "${AUTH_HEADER[@]}" "$API/repos/$full_name/git/trees/$commit_sha?recursive=1" || echo "{}")
      echo "$tree_resp" | jq '.' > "$repo_dir/tree_${commit_sha}.json"
    fi
  fi

  commits_resp=$(curl -s "${AUTH_HEADER[@]}" "$API/repos/$full_name/commits?per_page=$COMMITS_PER_REPO" || echo "[]")
  echo "$commits_resp" | jq '.' > "$repo_dir/commits.json"

  echo "  done $full_name"
done

echo "All done. Output saved under: $OUTDIR"
echo "Notes:"
echo "- READMEs saved as raw text where present (readme_raw)."
echo "- Trees are Git object trees for the default-branch commit (may be large)."
echo "- Commits saved as JSON; increase COMMITS_PER_REPO if you want more."
echo "- To avoid rate limits, set GITHUB_TOKEN env var (personal access token)."
