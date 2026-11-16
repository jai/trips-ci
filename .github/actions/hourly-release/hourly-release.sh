#!/usr/bin/env bash
# ready: a release commit on main whose release is not tagged yet: state=ready (with the components to tag) once its
#   checks passed, waiting while they run, none when there is no such commit or none of its components passed (that
#   version is skipped).
# publish: tag each ready component and publish its GitHub Release.
# decide: go=true when the last release (of any component) is an hour old or more.
# land: put release-please's release commit on main's head as a GitHub-signed fast-forward.
#
# Components (input `components`, JSON): {"<manifest path>": {"tag-prefix": "ios-v", "ci-workflows": ["ci.yml"],
#   "statuses": ["ui-works/iphone"], "latest": true}}. A release commit tags each component whose version it changed,
#   once that component's workflows (push runs) and commit statuses passed on it or on a later commit on main that
#   holds it. Without the input there is one component, ".", with `tag-prefix` and `ci-workflow`.
set -euo pipefail

repo="$GITHUB_REPOSITORY"

components() {
  if [[ -n "${COMPONENTS:-}" ]]; then
    jq -c . <<<"$COMPONENTS"
  else
    jq -nc --arg prefix "${TAG_PREFIX:-}" --arg workflow "${CI_WORKFLOW:-}" \
      '{".": {"tag-prefix": $prefix, "ci-workflows": [$workflow], "latest": true}}'
  fi
}

# "completed success" when any push run for the commit passed, or when the newest passing push run on main is on a
# later commit that holds it: that run tested the release commit's files too, and on a busy main a newer push keeps
# replacing the release commit's own waiting run (FeedbackKit 0.6.1, 2026-11-16). Otherwise the newest run that was
# not cancelled (a duplicate run someone cancelled says nothing about the commit).
ci_result() {
  local own later CI_WORKFLOW=$2
  own=$(gh api "repos/${repo}/actions/workflows/${CI_WORKFLOW}/runs?head_sha=$1&event=push&per_page=20" \
    --jq '.workflow_runs
          | if any(.[]; .conclusion == "success") then "completed success"
            else (map(select(.conclusion != "cancelled")) | sort_by(.created_at) | last
                  | if . == null then "" else "\(.status) \(.conclusion)" end)
            end')
  if [[ "$own" != "completed success" ]]; then
    later=$(gh api "repos/${repo}/actions/workflows/${CI_WORKFLOW}/runs?branch=main&event=push&status=success&per_page=1" \
      --jq '.workflow_runs[0].head_sha // empty')
    if [[ -n "$later" && "$later" != "$1" ]] &&
      [[ $(gh api "repos/${repo}/compare/$1...${later}" --jq .status) == ahead ]]; then
      echo "Release commit $1 holds in ${later}, whose ${CI_WORKFLOW} passed." >&2
      own="completed success"
    fi
  fi
  echo "$own"
}

# The commit statuses $2 (JSON list of contexts) for release commit $1: "success" when each one's newest state is
# success on the commit or on a later commit on main that holds it, "failure" when one failed or errored on the commit
# itself and no later commit passed them all, else "pending". One GraphQL call: the newest 100 commits on main.
status_result() {
  local history own later
  # shellcheck disable=SC2016 # GraphQL's variables.
  history=$(gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -f query='
    query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { ref(qualifiedName: "refs/heads/main") {
      target { ... on Commit { history(first: 100) { nodes { oid status { contexts { context state } } } } } } } } }' \
    --jq '[.data.repository.ref.target.history.nodes[] | {oid, contexts: [(.status.contexts // [])[] | {(.context): .state}] | add}]')
  own=$(jq -c --arg sha "$1" '.[] | select(.oid == $sha)' <<<"$history")
  if [[ -n "$own" ]] && jq -e --argjson want "$2" '(.contexts // {}) as $have | all($want[]; $have[.] == "SUCCESS")' \
    <<<"$own" >/dev/null; then
    echo success
    return
  fi
  git fetch --quiet origin main
  while read -r later; do
    [[ "$later" == "$1" ]] && break
    if git merge-base --is-ancestor "$1" "$later" 2>/dev/null; then
      echo "Release commit $1 holds in ${later}, whose statuses passed." >&2
      echo success
      return
    fi
  done < <(jq -r --argjson want "$2" --arg sha "$1" \
    '.[] | select(.oid == $sha or ((.contexts // {}) as $have | all($want[]; $have[.] == "SUCCESS"))) | .oid' <<<"$history")
  if [[ -n "$own" ]] && jq -e --argjson want "$2" '(.contexts // {}) as $have | any($want[]; $have[.] | IN("FAILURE", "ERROR"))' \
    <<<"$own" >/dev/null; then
    echo failure
  else
    echo pending
  fi
}

# One component of release commit $2 ($1, its config as JSON): ready, failed, or waiting (with the reason on stderr).
component_state() {
  local config=$1 sha=$2 workflow ci statuses st state=ready cancelled
  while read -r workflow; do
    [[ -n "$workflow" ]] || continue
    ci=$(ci_result "$sha" "$workflow")
    case "$ci" in
      "completed success") ;;
      completed\ *)
        echo "::warning::Release commit ${sha} did not pass ${workflow} (${ci})." >&2
        state=failed ;;
      "")
        # Every run for it was cancelled (GitHub drops older pending runs in a concurrency group): run it again.
        cancelled=$(gh api "repos/${repo}/actions/workflows/${workflow}/runs?head_sha=${sha}&event=push&per_page=20" \
          --jq '[.workflow_runs[] | select(.conclusion == "cancelled")] | sort_by(.created_at) | last | .id // empty')
        if [[ -n "$cancelled" ]]; then
          gh api -X POST "repos/${repo}/actions/runs/${cancelled}/rerun" >/dev/null
          echo "Release commit ${sha} had only cancelled ${workflow} runs; re-ran ${cancelled}." >&2
        else
          echo "Release commit ${sha} waits for its ${workflow} run (not started)." >&2
        fi
        [[ "$state" == failed ]] || state=waiting ;;
      *)
        echo "Release commit ${sha} waits for its ${workflow} run (${ci})." >&2
        [[ "$state" == failed ]] || state=waiting ;;
    esac
  done < <(jq -r '(."ci-workflows" // [])[]' <<<"$config")
  statuses=$(jq -c '.statuses // []' <<<"$config")
  if [[ "$statuses" != "[]" ]]; then
    st=$(status_result "$sha" "$statuses")
    case "$st" in
      success) ;;
      failure)
        echo "::warning::Release commit ${sha} failed its statuses ${statuses}." >&2
        state=failed ;;
      *)
        echo "Release commit ${sha} waits for its statuses ${statuses}." >&2
        [[ "$state" == failed ]] || state=waiting ;;
    esac
  fi
  echo "$state"
}

relabel() {
  gh api -X DELETE "repos/${repo}/issues/$1/labels/autorelease:%20pending" >/dev/null 2>&1 || true
  gh api "repos/${repo}/issues/$1/labels" -f "labels[]=autorelease: $2" >/dev/null
}

ready() {
  local number sha all single path config state tag ready_list="[]" waiting=0 tagged=0 released
  read -r number sha < <(gh api "repos/${repo}/pulls?state=closed&base=main&per_page=30" \
    --jq '[.[] | select(.merged_at != null) | select(any(.labels[]; .name == "autorelease: pending"))][0]
          | "\(.number // "") \(.head.sha // "")"')
  if [[ -z "${number:-}" ]]; then
    echo "state=none" >>"$GITHUB_OUTPUT"
    return
  fi
  all=$(components)
  single=$([[ -z "${COMPONENTS:-}" ]] && echo 1 || true)
  if [[ -n "$single" ]]; then
    released='["."]'
  else
    # The components whose version the release commit changed.
    git fetch --quiet origin main
    released=$(jq -nc --argjson now "$(git show "${sha}:${MANIFEST}")" --argjson before "$(git show "${sha}^:${MANIFEST}" 2>/dev/null || echo '{}')" \
      '[$now | keys[] | select($now[.] != $before[.])]')
  fi
  while read -r path; do
    config=$(jq -c --arg p "$path" '.[$p] // empty' <<<"$all")
    if [[ -z "$config" ]]; then
      echo "::warning::Release commit ${sha} (#${number}) changed ${path}, which has no entry in components; not tagged."
      continue
    fi
    tag="$(jq -r '."tag-prefix"' <<<"$config")"
    if [[ -z "$single" ]]; then
      tag="${tag}$(git show "${sha}:${MANIFEST}" | jq -r --arg p "$path" '.[$p]')"
      if gh api "repos/${repo}/git/refs/tags/${tag}" >/dev/null 2>&1; then
        tagged=$((tagged + 1))
        continue
      fi
    fi
    state=$(component_state "$config" "$sha")
    case "$state" in
      ready)
        echo "Release commit ${sha} (#${number}) passed for ${path}; tagging it."
        ready_list=$(jq -c --arg p "$path" '. + [$p]' <<<"$ready_list") ;;
      waiting) waiting=$((waiting + 1)) ;;
      *) echo "::warning::Release commit ${sha} (#${number}) did not pass for ${path}; skipping that version." ;;
    esac
  done < <(jq -r '.[]' <<<"$released")

  if [[ "$ready_list" != "[]" ]]; then
    { echo "state=ready"; echo "sha=${sha}"; echo "number=${number}"; echo "components=${ready_list}"
      echo "final=$([[ $waiting == 0 ]] && echo true || echo false)"; } >>"$GITHUB_OUTPUT"
  elif ((waiting > 0)); then
    echo "Release commit ${sha} (#${number}) waits for its checks."
    echo "state=waiting" >>"$GITHUB_OUTPUT"
  else
    # Nothing left to tag. A component tagged before keeps the release; with none, release-please stops tracking the
    # pull request, so the next release PR can open; that version is skipped.
    if ((tagged > 0)); then relabel "$number" tagged; else relabel "$number" failed; fi
    echo "state=none" >>"$GITHUB_OUTPUT"
  fi
}

# Tag each ready component's release commit and publish its GitHub Release, as release-please would: notes are this
# version's section of the component's changelog, the title "<component>: v<version>" (or the tag, for a bare v prefix),
# and once nothing waits the pull request moves to "autorelease: tagged".
publish() {
  local all path config prefix version tag title notes url changelog latest tags="" ready=${READY:-}
  [[ -n "$ready" ]] || ready='["."]'
  git fetch --quiet origin main
  all=$(components)
  while read -r path; do
    config=$(jq -c --arg p "$path" '.[$p]' <<<"$all")
    prefix=$(jq -r '."tag-prefix"' <<<"$config")
    version=$(git show "${SHA}:${MANIFEST}" | jq -r --arg p "$path" '.[$p]')
    tag="${prefix}${version}"
    # "frontend-v" names its component in the title ("frontend: v0.84.2"); a bare "v" prefix titles the release by its tag.
    if [[ "$prefix" == *-v ]]; then title="${prefix%-v}: v${version}"; else title="$tag"; fi
    changelog=$(git show "${SHA}:${CONFIG_FILE}" 2>/dev/null | jq -r --arg p "$path" '.packages[$p]."changelog-path" // "CHANGELOG.md"' \
      || echo CHANGELOG.md)
    [[ "$path" == "." ]] || changelog="${path}/${changelog}"
    notes=$(mktemp)
    git show "${SHA}:${changelog}" | awk '/^## /{n++} n==1' >"$notes"
    latest=--latest
    [[ $(jq -r '.latest // false' <<<"$config") == true ]] || latest=--latest=false

    if ! gh api "repos/${repo}/git/refs/tags/${tag}" >/dev/null 2>&1; then
      git push --quiet origin "${SHA}:refs/tags/${tag}"
    fi
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
      echo "${tag} is already published."
    else
      gh release create "$tag" --repo "$repo" --verify-tag --title "$title" --notes-file "$notes" "$latest"
    fi
    url=$(gh release view "$tag" --repo "$repo" --json url --jq .url)
    tags="${tags:+$tags }${tag}"
  done < <(jq -r '.[]' <<<"$ready")
  [[ "${FINAL:-true}" != true ]] || relabel "$PR_NUMBER" tagged
  { echo "release_created=true"; echo "tag_name=${tag}"; echo "html_url=${url}"; echo "tags=${tags}"; } >>"$GITHUB_OUTPUT"
}

decide() {
  local last age
  last=$(gh api "repos/${repo}/releases?per_page=50" \
    --jq "[.[] | select(.draft | not) | select(.tag_name as \$t | $(components | jq -c '[.[]."tag-prefix"]') | any(. as \$p | \$t | startswith(\$p)))][0].published_at // \"\"")
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
