#!/usr/bin/env bash
# decide: print sha=<main's head> when main's head passed CI and the last release is an hour old or more.
# land: put release-please's release commit on main as a GitHub-signed fast-forward of that commit.
set -euo pipefail

repo="$GITHUB_REPOSITORY"

decide() {
  local head last age ci
  head=$(gh api "repos/${repo}/commits/main" --jq .sha)

  last=$(gh api "repos/${repo}/releases?per_page=50" \
    --jq "[.[] | select(.draft | not) | select(.tag_name | startswith(\"${TAG_PREFIX}\"))][0].published_at // \"\"")
  if [[ -n "$last" ]]; then
    age=$(( $(date +%s) - $(date -d "$last" +%s) ))
    if (( age < 3600 )); then
      echo "The last release was ${age}s ago; releases are at most hourly."
      return
    fi
  fi

  # Only main's head can take the release commit as a fast-forward. A red or running head waits for the push that
  # fixes it, or for its own CI run, which starts this workflow again.
  ci=$(gh api "repos/${repo}/actions/workflows/${CI_WORKFLOW}/runs?head_sha=${head}&event=push&per_page=20" \
    --jq '.workflow_runs | sort_by(.created_at) | last | "\(.status) \(.conclusion)"')
  if [[ "$ci" != "completed success" ]]; then
    echo "main's head ${head} has no passed ${CI_WORKFLOW} run (${ci:-none}); nothing to release."
    return
  fi

  echo "Releasing ${head}."
  echo "sha=${head}" >>"$GITHUB_OUTPUT"
}

# shellcheck disable=SC2016
readonly mutation='mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}'

land() {
  local branch number head parent work temp commit state
  number=$(jq -r '.number // empty' <<<"${PR:-}")
  branch=$(jq -r '.headBranchName // empty' <<<"${PR:-}")
  if [[ -z "$number" ]]; then
    # release-please reports only a pull request it changed; an unchanged open one is still ours to land.
    read -r number branch < <(gh api "repos/${repo}/pulls?state=open&base=main&per_page=50" \
      --jq '[.[] | select(any(.labels[]; .name == "autorelease: pending"))][0] | "\(.number // "") \(.head.ref // "")"')
  fi
  if [[ -z "${number:-}" ]]; then
    echo "release-please found nothing to release since the last tag."
    return
  fi

  git fetch --quiet origin main "$branch"
  head=$(git rev-parse "origin/${branch}")
  parent=$(git rev-parse "${head}^")
  if [[ "$parent" != "$SHA" ]]; then
    echo "::warning::Release branch ${branch} is built on ${parent}, not on the tested ${SHA}; main moved. Next run."
    return
  fi

  # main accepts only verified commits: rebuild the release commit with createCommitOnBranch, which GitHub signs,
  # on a temporary branch at the tested commit.
  work=$(mktemp -d)
  temp="sign-release/${head}"
  trap 'gh api -X DELETE "repos/${repo}/git/refs/heads/${temp}" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
  gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${temp}" -f "sha=${SHA}" >/dev/null

  git diff --name-only --diff-filter=d "$SHA" "$head" | while IFS= read -r path; do
    git show "${head}:${path}" | base64 -w0 >"${work}/contents"
    jq -n --arg path "$path" --rawfile contents "${work}/contents" '{path: $path, contents: $contents}'
  done >"${work}/additions.json"
  git diff --name-only --diff-filter=D "$SHA" "$head" | jq -R '{path: .}' >"${work}/deletions.json"

  jq -n \
    --arg query "$mutation" \
    --arg repository "$repo" \
    --arg branch "$temp" \
    --arg base "$SHA" \
    --arg headline "$(git log -1 --format=%s "$head")" \
    --arg body "$(git log -1 --format=%b "$head")" \
    --slurpfile additions "${work}/additions.json" \
    --slurpfile deletions "${work}/deletions.json" \
    '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repository, branchName: $branch},
      expectedHeadOid: $base,
      message: {headline: $headline, body: $body},
      fileChanges: {additions: $additions, deletions: $deletions}
    }}}' >"${work}/request.json"
  commit=$(gh api graphql --input "${work}/request.json" --jq .data.createCommitOnBranch.commit.oid)

  gh api -X PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=${commit}" -F force=true >/dev/null
  # A fast-forward only: GitHub refuses it when main moved past the tested commit.
  if ! gh api -X PATCH "repos/${repo}/git/refs/heads/main" -f "sha=${commit}" -F force=false >/dev/null; then
    echo "::warning::main moved past ${SHA}; the release waits for the next run."
    return
  fi
  echo "main is now the release commit ${commit}."

  # GitHub marks the pull request merged once its head is on main; release-please tags only merged ones.
  for _ in $(seq 1 30); do
    state=$(gh pr view "$number" --repo "$repo" --json state --jq .state)
    [[ "$state" == MERGED ]] && return
    sleep 4
  done
  echo "::error::Pull request #${number} is not marked merged; tag ${commit} by running this workflow again."
  exit 1
}

"$@"
