# Review Workflow Validation Matrix

> Ref: [Issue #54](https://github.com/jai/trips-ci/issues/54) · [PR #55](https://github.com/jai/trips-ci/pull/55)
>
> Purpose: executable use-case matrix for validating CI-owned review decision orchestration.

---

## Decision Marker Schema (reference)

```text
<!-- CLAUDE_REVIEW_DECISION -->
DECISION=APPROVE|REQUEST_CHANGES
BLOCKER=<required when REQUEST_CHANGES>
NEXT_ACTION=<required when REQUEST_CHANGES>
<!-- /CLAUDE_REVIEW_DECISION -->
```

Parser rules:
- Only comments authored by the automation actor (`gh api user` login) count.
- Only comments created **after** the run start timestamp count.
- Latest valid marker wins.
- No fallback to existing review state.

---

## Use-Case Matrix

### UC-01 · APPROVE — clean path (0 unresolved threads)

- **Trigger/event**: `pull_request` (opened | reopened | synchronize | review_requested) or `/review` slash command
- **Preconditions**:
  - PR exists, not draft (or draft with UC-02).
  - Claude posts valid `DECISION=APPROVE` marker.
  - All review threads resolved (unresolved = 0).
- **Expected decision path**: `parse-review-decision` → `decision_found=true`, `decision=APPROVE`
- **Expected workflow actions**:
  1. `review-orchestration` job runs.
  2. Thread count computed: `unresolved_threads=0`.
  3. Approval precondition passes.
  4. `gh pr review --approve` submitted by workflow with body containing "CI approval".
- **Expected PR outcome**: PR shows `APPROVED` review from CI actor.
- **Evidence to capture**:
  - Workflow run URL (both `review` and `review-orchestration` jobs green).
  - PR review list: `gh pr reviews <PR> --json author,state` shows `APPROVED` from automation user.
  - PR comment containing `<!-- CLAUDE_REVIEW_DECISION -->` with `DECISION=APPROVE`.
  - `review-orchestration` job log line: `✅ Approval precondition satisfied: unresolved_threads=0`.

#### Validation Playbook

```bash
# Variables
REPO="jai/trips-frontend"  # or test repo
PR_NUMBER=<test-pr>

# 1. Trigger review
gh pr comment "$PR_NUMBER" --repo "$REPO" --body "/review"

# 2. Wait for workflow to complete
gh run list --repo "$REPO" --branch "$(gh pr view $PR_NUMBER --repo $REPO --json headRefName -q .headRefName)" \
  --workflow "code-review.yaml" --limit 1 --json status,conclusion,databaseId

# 3. Assert: decision marker exists
gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
  | jq '[.[] | select(.body | contains("CLAUDE_REVIEW_DECISION")) | select(.body | contains("DECISION=APPROVE"))] | length'
# PASS: >= 1

# 4. Assert: workflow-submitted APPROVED review
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate \
  | jq '[.[] | select(.state == "APPROVED") | select(.body | contains("CI approval"))] | length'
# PASS: >= 1

# 5. Assert: review-orchestration job succeeded
RUN_ID=$(gh run list --repo "$REPO" --branch "$(gh pr view $PR_NUMBER --repo $REPO --json headRefName -q .headRefName)" \
  --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq '.jobs[] | select(.name | contains("Review Orchestration")) | {name, conclusion}'
# PASS: conclusion == "success"
```

**Pass criteria**: All 3 assertions return expected values; both jobs green.
**Fail criteria**: Any assertion fails, or `review-orchestration` job is red/skipped.

---

### UC-02 · APPROVE — draft PR transitions to ready

- **Trigger/event**: `/review` slash command on a draft PR
- **Preconditions**:
  - PR is in draft state (`gh pr view --json isDraft` → `true`).
  - Claude posts valid `DECISION=APPROVE` marker.
  - All review threads resolved.
- **Expected decision path**: Same as UC-01.
- **Expected workflow actions**:
  1. Thread count: `unresolved_threads=0`.
  2. `gh pr ready` called (draft → ready transition).
  3. `gh pr review --approve` submitted.
- **Expected PR outcome**: PR is no longer draft; `APPROVED` review posted.
- **Evidence to capture**:
  - `gh pr view --json isDraft` → `false` after run.
  - Job log line: `gh pr ready` executed.
  - Same approval evidence as UC-01.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<draft-test-pr>

# Pre-check: PR is draft
gh pr view "$PR_NUMBER" --repo "$REPO" --json isDraft -q '.isDraft'
# Expected: true

# Trigger
gh pr comment "$PR_NUMBER" --repo "$REPO" --body "/review"

# Wait for completion (poll run)
# ... same as UC-01 step 2 ...

# Assert: PR is no longer draft
gh pr view "$PR_NUMBER" --repo "$REPO" --json isDraft -q '.isDraft'
# PASS: false

# Assert: APPROVED review posted (same as UC-01 steps 3-4)
```

**Pass criteria**: PR transitions from draft to ready AND approval posted.

---

### UC-03 · REQUEST_CHANGES — blocker path

- **Trigger/event**: `pull_request` event or `/review` slash command
- **Preconditions**:
  - Claude posts valid `DECISION=REQUEST_CHANGES` marker with both `BLOCKER` and `NEXT_ACTION`.
- **Expected decision path**: `parse-review-decision` → `decision_found=true`, `decision=REQUEST_CHANGES`, `blocker` and `next_action` populated.
- **Expected workflow actions**:
  1. `review-orchestration` job runs.
  2. Workflow submits `REQUEST_CHANGES` review via `gh pr review --request-changes`.
  3. Review body contains `BLOCKED: <blocker>` and `Next action: <next_action>`.
- **Expected PR outcome**: PR shows `CHANGES_REQUESTED` review from CI actor.
- **Evidence to capture**:
  - PR review: `gh api repos/$REPO/pulls/$PR_NUMBER/reviews` shows `CHANGES_REQUESTED` with body containing `BLOCKED:`.
  - Workflow run URL with both jobs green.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<test-pr>

# Trigger review
gh pr comment "$PR_NUMBER" --repo "$REPO" --body "/review"

# Wait for completion...

# Assert: decision marker with REQUEST_CHANGES
gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
  | jq '[.[] | select(.body | contains("DECISION=REQUEST_CHANGES"))] | length'
# PASS: >= 1

# Assert: REQUEST_CHANGES review submitted by workflow
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate \
  | jq '[.[] | select(.state == "CHANGES_REQUESTED") | select(.body | contains("BLOCKED:"))] | length'
# PASS: >= 1

# Assert: review body contains blocker + next_action
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate \
  | jq '[.[] | select(.state == "CHANGES_REQUESTED")] | last | .body'
# PASS: contains "BLOCKED:" and "Next action:"
```

**Pass criteria**: `CHANGES_REQUESTED` review posted with blocker details.

---

### UC-04 · APPROVE + unresolved threads > 0 → BLOCKED (negative path)

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude posts valid `DECISION=APPROVE` marker.
  - At least 1 unresolved review thread exists on the PR.
- **Expected decision path**: `decision_found=true`, `decision=APPROVE`.
- **Expected workflow actions**:
  1. `review-orchestration` runs.
  2. Thread count computed: `unresolved_threads > 0`.
  3. **"Enforce approval precondition" step fails** with error message.
  4. No `gh pr review --approve` is submitted.
  5. `review-orchestration` job fails.
- **Expected PR outcome**: NO `APPROVED` review from this run. PR remains without CI approval.
- **Evidence to capture**:
  - `review-orchestration` job conclusion: `failure`.
  - Job log contains: `DECISION=APPROVE requires unresolved_threads=0, but PR #<N> has <N> unresolved review thread(s)`.
  - No new `APPROVED` review from automation user for this run window.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<test-pr-with-unresolved-thread>

# Setup: ensure at least 1 unresolved review thread exists
# (manually leave a review comment unresolved, or create one via API)

# Simulate: post APPROVE marker as automation user
# (In real flow, Claude would post this; for testing, force-post the marker)
AUTOMATION_USER=$(gh api user --jq '.login')
gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=APPROVE
<!-- /CLAUDE_REVIEW_DECISION -->'

# Trigger review or let the existing run proceed

# Assert: review-orchestration job failed
RUN_ID=$(gh run list --repo "$REPO" --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq '.jobs[] | select(.name | contains("Review Orchestration")) | .conclusion'
# PASS: "failure"

# Assert: no APPROVED review from this run
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate \
  | jq '[.[] | select(.state == "APPROVED") | select(.body | contains("CI approval"))] | length'
# PASS: 0 (or no new ones from this run)

# Assert: error annotation in logs
gh run view "$RUN_ID" --repo "$REPO" --log 2>&1 | grep -c "DECISION=APPROVE requires unresolved_threads=0"
# PASS: >= 1
```

**Pass criteria**: Orchestration job fails; no approval posted; error message logged.
**Fail criteria**: Approval posted despite unresolved threads.

---

### UC-05 · Missing decision marker → fail closed (negative path)

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude completes review but does NOT post a `<!-- CLAUDE_REVIEW_DECISION -->` marker.
- **Expected decision path**: `parse-review-decision` → `decision_found=false`.
- **Expected workflow actions**:
  1. `review` job completes with `decision_found=false`.
  2. `review-orchestration` job is **skipped** (its `if` condition: `needs.review.outputs.decision_found == 'true'`).
  3. No `gh pr review` action submitted.
- **Expected PR outcome**: No review state change. PR stays as-is.
- **Evidence to capture**:
  - `review` job output: `decision_found=false`.
  - `review-orchestration` job status: `skipped`.
  - Warning annotation: `No valid CLAUDE_REVIEW_DECISION marker found`.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<test-pr>

# Scenario: Claude ran but didn't post marker
# (This would need a test where Claude's prompt is modified, or marker is manually deleted after run)

# Assert: review job outputs
RUN_ID=$(gh run list --repo "$REPO" --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')

# Check review-orchestration was skipped
gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq '.jobs[] | select(.name | contains("Review Orchestration")) | {name, conclusion}'
# PASS: conclusion == "skipped" or conclusion == null (job didn't run)

# Check warning in logs
gh run view "$RUN_ID" --repo "$REPO" --log 2>&1 | grep -c "No valid CLAUDE_REVIEW_DECISION marker found"
# PASS: >= 1
```

**Pass criteria**: Orchestration skipped; warning logged; no review action taken.

---

### UC-06 · Invalid decision value → fail closed (negative path)

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude posts a marker block with `DECISION=LGTM` (or any value other than `APPROVE`/`REQUEST_CHANGES`).
- **Expected decision path**: Parser's `case` statement falls through to `*)`; marker is not valid → `decision_found=false`.
- **Expected workflow actions**: Same as UC-05 — orchestration skipped.
- **Expected PR outcome**: No review state change.
- **Evidence to capture**: Same as UC-05.

#### Validation Playbook

```bash
# Simulate: post marker with invalid decision
gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=LGTM
<!-- /CLAUDE_REVIEW_DECISION -->'

# Then trigger review and verify same assertions as UC-05
```

**Pass criteria**: `decision_found=false`; orchestration skipped.

---

### UC-07 · REQUEST_CHANGES without BLOCKER → fail closed (negative path)

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude posts marker: `DECISION=REQUEST_CHANGES` but omits `BLOCKER=`.
- **Expected decision path**: Parser requires both `BLOCKER` and `NEXT_ACTION` for `REQUEST_CHANGES` to be valid. Missing `BLOCKER` → marker invalid → `decision_found=false`.
- **Expected workflow actions**: Same as UC-05 — orchestration skipped.
- **Expected PR outcome**: No review state change.

#### Validation Playbook

```bash
# Simulate: REQUEST_CHANGES without BLOCKER
gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=REQUEST_CHANGES
NEXT_ACTION=Fix the tests
<!-- /CLAUDE_REVIEW_DECISION -->'

# Assertions same as UC-05
```

**Pass criteria**: `decision_found=false`; orchestration skipped.

---

### UC-08 · REQUEST_CHANGES without NEXT_ACTION → fail closed (negative path)

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude posts marker: `DECISION=REQUEST_CHANGES` with `BLOCKER=` but omits `NEXT_ACTION=`.
- **Expected decision path**: Same as UC-07 — marker invalid → `decision_found=false`.
- **Expected workflow actions**: Same as UC-05.

#### Validation Playbook

```bash
# Simulate: REQUEST_CHANGES without NEXT_ACTION
gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=REQUEST_CHANGES
BLOCKER=Merge conflict
<!-- /CLAUDE_REVIEW_DECISION -->'

# Assertions same as UC-05
```

**Pass criteria**: `decision_found=false`; orchestration skipped.

---

### UC-09 · Conversational @claude cannot approve/request-changes (respond workflow)

- **Trigger/event**: `issue_comment` containing `@claude` (not `/review`) OR `pull_request_review_comment` containing `@claude`
- **Preconditions**:
  - Comment contains `@claude` but does NOT start with `/`.
  - Respond workflow runs (not full-review workflow).
- **Expected decision path**: No decision parsing occurs (respond workflow has no `parse-review-decision` step).
- **Expected workflow actions**:
  1. `respond` job runs with conversational prompt.
  2. Prompt contains `CONVERSATIONAL-ONLY RULE (MANDATORY)`.
  3. `allowedTools` excludes:
     - `mcp__github__create_pending_pull_request_review`
     - `mcp__github__submit_pending_pull_request_review`
  4. Claude can only post conversational comments.
- **Expected PR outcome**: No review state change. Only conversational reply posted.
- **Evidence to capture**:
  - Workflow YAML inspection: `allowedTools` in respond workflow does NOT contain `create_pending_pull_request_review` or `submit_pending_pull_request_review`.
  - Prompt text contains `Never approve a PR and never request changes`.
  - No new `APPROVED` or `CHANGES_REQUESTED` reviews from automation user.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<test-pr>

# 1. Post conversational @claude comment
gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@claude Can you explain the approach here?"

# 2. Wait for respond workflow to complete
RUN_ID=$(gh run list --repo "$REPO" --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')

# 3. Static check: verify allowedTools in code-review-respond.yaml
grep -c "create_pending_pull_request_review\|submit_pending_pull_request_review" \
  .github/workflows/code-review-respond.yaml
# PASS: 0 (not present)

# 4. Assert: no new review state changes from automation user
REVIEWS_BEFORE=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate | jq 'length')
# (wait for respond workflow to complete)
REVIEWS_AFTER=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate | jq 'length')
# PASS: REVIEWS_AFTER == REVIEWS_BEFORE (or any new reviews are COMMENT type only)

# 5. Assert: conversational reply posted
gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
  | jq '[.[] | select(.body | contains("explain") or contains("approach"))] | length'
# PASS: reply comment exists
```

**Pass criteria**: Conversational reply posted; no review state change; MCP tools excluded from allowedTools.

---

### UC-10 · `/review` slash command trigger

- **Trigger/event**: `issue_comment` with body starting with `/review`
- **Preconditions**:
  - Comment is on a PR (not a plain issue).
  - Comment body starts with `/review` (with optional args after).
- **Expected decision path**: `extract-context` → `context_type=slash_review`, `trigger_desc=/review slash command`.
- **Expected workflow actions**: Full review runs; same decision flow as UC-01/UC-03 depending on Claude's decision.
- **Expected PR outcome**: Full review with decision marker posted.
- **Evidence to capture**:
  - `review` job log: `context_type=slash_review`.
  - Decision marker comment posted.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"
PR_NUMBER=<test-pr>

# Trigger
gh pr comment "$PR_NUMBER" --repo "$REPO" --body "/review please focus on error handling"

# Assert: full review ran (not respond)
RUN_ID=$(gh run list --repo "$REPO" --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN_ID" --repo "$REPO" --log 2>&1 | grep "context_type=slash_review"
# PASS: match found

# Assert: slash_args captured
gh run view "$RUN_ID" --repo "$REPO" --log 2>&1 | grep "please focus on error handling"
# PASS: match found
```

---

### UC-11 · PR event triggers (pull_request actions)

- **Trigger/event**: `pull_request` with action in `{opened, reopened, ready_for_review, synchronize, review_requested}`
- **Preconditions**: PR event fires from a caller repo's `code-review.yaml`.
- **Expected decision path**: `extract-context` → `context_type=pr_event`.
- **Expected workflow actions**: Full review runs.
- **Evidence to capture**:
  - Workflow trigger event matches expected action.
  - Review job completes.

#### Validation Playbook

```bash
REPO="jai/trips-frontend"

# Test "opened": create a new PR
gh pr create --repo "$REPO" --title "test: validation UC-11" --body "test PR" --head test-branch

# Test "synchronize": push a commit to existing PR branch
# Test "ready_for_review": convert draft to ready via gh pr ready

# For each, verify:
RUN_ID=$(gh run list --repo "$REPO" --workflow "code-review.yaml" --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN_ID" --repo "$REPO" --json jobs | jq '.jobs[] | {name, conclusion}'
# PASS: review job ran with conclusion "success"
```

---

### UC-12 · Multiple decision markers → latest valid wins

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - Claude posts TWO valid marker comments during the same run window (both after `started_at`, both from automation user).
  - First: `DECISION=REQUEST_CHANGES` (with blocker/next_action).
  - Second (later timestamp): `DECISION=APPROVE`.
- **Expected decision path**: Parser sorts by `created_at` descending, picks first valid → `DECISION=APPROVE`.
- **Expected workflow actions**: Same as UC-01 (assuming threads resolved).
- **Evidence to capture**:
  - Two marker comments visible on PR.
  - Workflow acted on `APPROVE` (the later one).

#### Validation Playbook

```bash
# Simulate: post two markers as automation user in sequence
gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=REQUEST_CHANGES
BLOCKER=test blocker
NEXT_ACTION=test action
<!-- /CLAUDE_REVIEW_DECISION -->'

sleep 2

gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=APPROVE
<!-- /CLAUDE_REVIEW_DECISION -->'

# Trigger and verify APPROVE is the acted-upon decision
```

---

### UC-13 · Marker from non-automation user → ignored

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - A human user (not the automation actor) posts a comment containing a valid `CLAUDE_REVIEW_DECISION` marker.
  - No marker from the automation user exists.
- **Expected decision path**: Parser filters by `automation_login` → no candidates → `decision_found=false`.
- **Expected workflow actions**: Same as UC-05 — orchestration skipped.

#### Validation Playbook

```bash
# As a regular user (not the GH App / PAT user), post:
# <!-- CLAUDE_REVIEW_DECISION -->
# DECISION=APPROVE
# <!-- /CLAUDE_REVIEW_DECISION -->

# Then trigger review and verify decision_found=false (same as UC-05)
```

---

### UC-14 · Marker created before run start → ignored

- **Trigger/event**: Any full-review trigger
- **Preconditions**:
  - A valid `DECISION=APPROVE` marker exists from the automation user, but its `created_at` is before the current run's `started_at`.
- **Expected decision path**: Parser filters by `created_at >= run_started_at` → no candidates → `decision_found=false`.
- **Expected workflow actions**: Same as UC-05 — orchestration skipped.

---

### UC-15 · APPROVE + empty commit CI trigger

- **Trigger/event**: APPROVE decision on a PR where check runs show `action_required` or no check runs exist
- **Preconditions**:
  - `DECISION=APPROVE`, threads resolved.
  - Head SHA has 0 check runs OR some `action_required` check runs.
  - PR head repo == target repo (not a fork).
- **Expected workflow actions**:
  1. `checks` step: `should_trigger=true`.
  2. `duplicate-commit` step: `already_triggered=false`.
  3. Empty commit pushed: `ci: trigger checks after claude review decision`.
  4. Approval submitted.
- **Evidence to capture**:
  - Commit history includes empty commit with expected message.
  - Job log: trigger reason logged.

---

### UC-16 · APPROVE + fork PR → skip empty commit

- **Trigger/event**: APPROVE on a fork PR
- **Preconditions**:
  - `head_repo != github.repository` (fork).
- **Expected workflow actions**:
  - "Skip CI trigger commit for fork PRs" step runs.
  - No empty commit pushed.
  - Approval still submitted.
- **Evidence to capture**:
  - Job log notice: `skipping empty commit because branch is not local to target repo`.

---

### UC-17 · No READY_FOR_REVIEW references in workflow

- **Trigger/event**: Static analysis (no runtime trigger needed)
- **Preconditions**: Merged code from PR #55.
- **Expected outcome**: No `READY_FOR_REVIEW` protocol references in workflow files (the GitHub event action `ready_for_review` is allowed).

#### Validation Playbook

```bash
cd /root/Developer/trips/trips-ci

# Assert: no READY_FOR_REVIEW as a protocol marker
grep -rn "READY_FOR_REVIEW" .github/workflows/code-review-full.yaml .github/workflows/code-review-respond.yaml \
  | grep -v "ready_for_review" | grep -v "# " || true
# PASS: 0 matches (only lowercase ready_for_review event action is acceptable)

# Assert: no instructions to run gh pr review --approve in prompts
grep -c "gh pr review.*--approve" .github/workflows/code-review-full.yaml
# PASS: only in the review-orchestration step (workflow-owned), NOT in prompt text

# Assert: MCP review submission tools removed
grep -c "create_pending_pull_request_review\|submit_pending_pull_request_review" \
  .github/workflows/code-review-full.yaml .github/workflows/code-review-respond.yaml
# PASS: 0
```

---

## Quick Reference: Covered Cases Checklist

- **UC-01**: ✅ APPROVE clean path (0 unresolved threads)
- **UC-02**: ✅ APPROVE with draft→ready transition
- **UC-03**: ✅ REQUEST_CHANGES with blocker + next_action
- **UC-04**: ❌ APPROVE + unresolved threads > 0 → blocked (negative)
- **UC-05**: ❌ Missing decision marker → fail closed (negative)
- **UC-06**: ❌ Invalid decision value → fail closed (negative)
- **UC-07**: ❌ REQUEST_CHANGES without BLOCKER → fail closed (negative)
- **UC-08**: ❌ REQUEST_CHANGES without NEXT_ACTION → fail closed (negative)
- **UC-09**: 🔒 Conversational @claude cannot approve/request-changes
- **UC-10**: ✅ `/review` slash command trigger
- **UC-11**: ✅ PR event triggers (opened/reopened/synchronize/ready_for_review/review_requested)
- **UC-12**: ✅ Multiple markers → latest valid wins
- **UC-13**: ❌ Marker from wrong user → ignored (negative)
- **UC-14**: ❌ Marker before run start → ignored (negative)
- **UC-15**: ✅ Empty commit CI trigger logic
- **UC-16**: ✅ Fork PR → skip empty commit
- **UC-17**: 🔍 Static: no READY_FOR_REVIEW protocol remnants

Legend: ✅ happy path · ❌ negative/failure path · 🔒 safety constraint · 🔍 static check

---

## Recommended Validation Order

1. **UC-17** — static checks (no deployment needed)
2. **UC-01** — baseline approve path
3. **UC-03** — request-changes path
4. **UC-04** — thread violation (critical safety invariant)
5. **UC-05** — missing marker fail-closed
6. **UC-09** — respond workflow safety
7. **UC-02** — draft transition
8. Remaining edge cases as time permits

---

## Test Repo Setup

All runtime tests should target `jai/trips-frontend` (or another caller repo that uses `code-review.yaml` calling the reusable workflow).

For negative-path tests (UC-04 through UC-08), manual marker injection may be needed:
```bash
# Post a decision marker as the automation user
gh api "repos/$REPO/issues/$PR_NUMBER/comments" \
  -f body='<!-- CLAUDE_REVIEW_DECISION -->
DECISION=<value>
BLOCKER=<if needed>
NEXT_ACTION=<if needed>
<!-- /CLAUDE_REVIEW_DECISION -->'
```

For UC-04 specifically, create an unresolved review thread:
```bash
# Create inline review comment (creates an unresolved thread)
gh api "repos/$REPO/pulls/$PR_NUMBER/comments" \
  -f body="Test unresolved thread" \
  -f commit_id="$(gh pr view $PR_NUMBER --repo $REPO --json headRefName -q .headRefName)" \
  -f path="README.md" \
  -F line=1
```
