#!/usr/bin/env bash
# ready: a release commit on main whose release is not tagged yet: state=ready once its CI run passed, waiting while it
#   runs, failed (that version is skipped) when it did not pass; none when there is no such commit.
# decide: go=true when the last release is an hour old or more.
# land: put release-please's release commit on main's head as a GitHub-signed fast-forward.
set -euo pipefail

repo="$GITHUB_REPOSITORY"

# "completed success" when any push run for the commit passed; otherwise the newest run that was not cancelled (a
# duplicate run someone cancelled says nothing about the commit).
ci_result() {
  gh api "repos/${repo}/actions/workflows/${CI_WORKFLOW}/runs?head_sha=$1&event=push&per_page=20" \
    --jq '.workflow_runs
          | if any(.[]; .conclusion == "success") then "completed success"
            else (map(select(.conclusion != "cancelled")) | sort_by(.created_at) | last
                  | if . == null then "" else "\(.status) \(.conclusion)" end)
            end'
}

ready() {
  local number sha ci
  read -r number sha < <(gh api "repos/${repo}/pulls?state=closed&base=main&per_page=30" \
    --jq '[.[] | select(.merged_at != null) | select(any(.labels[]; .name == "autorelease: pending"))][0]
          | "\(.number // "") \(.head.sha // "")"')
  if [[ -z "${number:-}" ]]; then
    echo "state=none" >>"$GITHUB_OUTPUT"
    return
  fi
  ci=$(ci_result "$sha")
  case "$ci" in
    "completed success")
      echo "Release commit ${sha} (#${number}) passed ${CI_WORKFLOW}; tagging it."
      { echo "state=ready"; echo "sha=${sha}"; echo "number=${number}"; } >>"$GITHUB_OUTPUT" ;;
    completed\ *)
      # release-please stops tracking the pull request, so the next release PR can open; that version is skipped.
      echo "::warning::Release commit ${sha} (#${number}) did not pass ${CI_WORKFLOW} (${ci}); skipping that version."
      gh api -X DELETE "repos/${repo}/issues/${number}/labels/autorelease:%20pending" >/dev/null
      gh api "repos/${repo}/issues/${number}/labels" -f "labels[]=autorelease: failed" >/dev/null
      echo "state=none" >>"$GITHUB_OUTPUT" ;;
    *)
      echo "Release commit ${sha} (#${number}) waits for its ${CI_WORKFLOW} run (${ci:-not started})."
      echo "state=waiting" >>"$GITHUB_OUTPUT" ;;
  esac
}

# Tag the release commit and publish its GitHub Release, as release-please would: notes are this version's CHANGELOG.md
# section, the title "<component>: v<version>", and the pull request moves to "autorelease: tagged".
publish() {
  local version tag component notes url
  git fetch --quiet origin main
  version=$(git show "${SHA}:${MANIFEST}" | jq -r '."."')
  tag="${TAG_PREFIX}${version}"
  component="${TAG_PREFIX%-v}"
  notes=$(mktemp)
  git show "${SHA}:CHANGELOG.md" | awk '/^## /{n++} n==1' >"$notes"

  if ! gh api "repos/${repo}/git/refs/tags/${tag}" >/dev/null 2>&1; then
    git push --quiet origin "${SHA}:refs/tags/${tag}"
  fi
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "${tag} is already published."
  else
    gh release create "$tag" --repo "$repo" --verify-tag --title "${component}: v${version}" --notes-file "$notes" --latest
  fi
  gh api -X DELETE "repos/${repo}/issues/${PR_NUMBER}/labels/autorelease:%20pending" >/dev/null 2>&1 || true
  gh api "repos/${repo}/issues/${PR_NUMBER}/labels" -f "labels[]=autorelease: tagged" >/dev/null
  url=$(gh release view "$tag" --repo "$repo" --json url --jq .url)
  { echo "release_created=true"; echo "tag_name=${tag}"; echo "html_url=${url}"; } >>"$GITHUB_OUTPUT"
}

decide() {
  local last age
  last=$(gh api "repos/${repo}/releases?per_page=50" \
    --jq "[.[] | select(.draft | not) | select(.tag_name | startswith(\"${TAG_PREFIX}\"))][0].published_at // \"\"")
  if [[ -n "$last" ]]; then
    age=$(( $(date +%s) - $(date -d "$last" +%s) ))
    if (( age < 3600 )); then
      echo "The last release was ${age}s ago; releases are at most hourly."
      return
    fi
  fi
  echo "go=true" >>"$GITHUB_OUTPUT"
}

# shellcheck disable=SC2016
readonly mutation='mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}'

land() {
  local branch number head parent files work temp commit state
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

  # The release goes on main's head as it is now; its own CI run decides whether it gets tagged.
  SHA=$(gh api "repos/${repo}/commits/main" --jq .sha)
  git fetch --quiet origin main "$branch"
  head=$(git rev-parse "origin/${branch}")
  parent=$(git rev-parse "${head}^")
  # release-please leaves its branch alone when the release notes did not change (a ci: or docs: push), so the branch
  # can sit on an older main. Its files (version, changelog, manifest) carry over to the tested commit only when
  # nothing between the two touched them.
  files=$(git diff --name-only "$parent" "$head")
  # shellcheck disable=SC2086 # one path per word
  if [[ "$parent" != "$SHA" ]] && ! git diff --quiet "$parent" "$SHA" -- $files; then
    echo "::warning::${branch} is built on ${parent}; main changed its files since. release-please rebuilds it next run."
    gh api -X DELETE "repos/${repo}/git/refs/heads/${branch}" >/dev/null || true
    return
  fi

  # main accepts only verified commits: rebuild the release commit with createCommitOnBranch, which GitHub signs,
  # on a temporary branch at the tested commit.
  work=$(mktemp -d)
  temp="sign-release/${head}"
  # Expanded now: temp and work are locals, gone by the time the EXIT trap runs under set -u.
  # shellcheck disable=SC2064
  trap "gh api -X DELETE 'repos/${repo}/git/refs/heads/${temp}' >/dev/null 2>&1 || true; rm -rf '${work}'" EXIT
  gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${temp}" -f "sha=${SHA}" >/dev/null

  git diff --name-only --diff-filter=d "$parent" "$head" | while IFS= read -r path; do
    git show "${head}:${path}" | base64 -w0 >"${work}/contents"
    jq -n --arg path "$path" --rawfile contents "${work}/contents" '{path: $path, contents: $contents}'
  done >"${work}/additions.json"
  git diff --name-only --diff-filter=D "$parent" "$head" | jq -R '{path: .}' >"${work}/deletions.json"

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
  # A fast-forward only: GitHub refuses it when main moved meanwhile.
  if ! gh api -X PATCH "repos/${repo}/git/refs/heads/main" -f "sha=${commit}" -F force=false >/dev/null; then
    echo "::warning::main moved past ${SHA} meanwhile; the next run lands the release."
    return
  fi
  echo "main is now the release commit ${commit}."
  echo "landed=true" >>"$GITHUB_OUTPUT"

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
