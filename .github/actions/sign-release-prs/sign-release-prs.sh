#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2016
readonly mutation='mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}'

sign_branch() {
  # temp_branch and work_directory stay global: the EXIT trap outlives this
  # function, and each branch runs in its own subshell.
  local branch="$1" head base path commit
  git fetch --quiet origin main "$branch"
  head=$(git rev-parse "origin/${branch}")
  base=$(git merge-base origin/main "origin/${branch}")
  if [[ "$(gh api "repos/${GITHUB_REPOSITORY}/commits/${head}" --jq .commit.verification.verified)" == true ]]; then
    echo "${branch} is already signed"
    return
  fi

  # createCommitOnBranch can only append, and resetting the PR branch to base
  # would leave it with no diff, so build the commit on a temporary branch.
  temp_branch="sign-release/${head}"
  work_directory=$(mktemp -d)
  trap 'gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${temp_branch}" >/dev/null || true; rm -rf "$work_directory"' EXIT
  gh api "repos/${GITHUB_REPOSITORY}/git/refs" -f "ref=refs/heads/${temp_branch}" -f "sha=${base}" >/dev/null

  git diff --name-only --diff-filter=d "$base" "origin/${branch}" | while IFS= read -r path; do
    git show "origin/${branch}:${path}" | base64 -w0 >"${work_directory}/contents"
    jq -n --arg path "$path" --rawfile contents "${work_directory}/contents" '{path: $path, contents: $contents}'
  done >"${work_directory}/additions.json"
  git diff --name-only --diff-filter=D "$base" "origin/${branch}" | jq -R '{path: .}' >"${work_directory}/deletions.json"

  jq -n \
    --arg query "$mutation" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg branch "$temp_branch" \
    --arg base "$base" \
    --arg headline "$(git log -1 --format=%s "origin/${branch}")" \
    --arg body "$(git log -1 --format=%b "origin/${branch}")" \
    --slurpfile additions "${work_directory}/additions.json" \
    --slurpfile deletions "${work_directory}/deletions.json" \
    '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repository, branchName: $branch},
      expectedHeadOid: $base,
      message: {headline: $headline, body: $body},
      fileChanges: {additions: $additions, deletions: $deletions}
    }}}' >"${work_directory}/request.json"

  commit=$(gh api graphql --input "${work_directory}/request.json" --jq .data.createCommitOnBranch.commit.oid)
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch}" -f "sha=${commit}" -F force=true >/dev/null
  echo "Signed ${branch} as ${commit}"
}

# Ask GitHub for open release PRs: release-please reports only the PRs it
# changed, so an unchanged unsigned PR would otherwise stay blocked.
gh pr list --repo "$GITHUB_REPOSITORY" --state open --label 'autorelease: pending' \
  --json headRefName --jq '.[].headRefName' | while IFS= read -r branch; do
  (sign_branch "$branch")
done
