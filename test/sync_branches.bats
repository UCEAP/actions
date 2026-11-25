#!/usr/bin/env bats
# Tests for scripts/sync_branches.sh, the logic behind sync_branches.yml.
# Each test maps to a behaviour documented in README.md.

load test_helper

# --- Inputs ------------------------------------------------------------------

@test "fails when REPO is not set" {
  unset REPO
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REPO"* ]]
}

@test "fails when the compare API call fails" {
  stub_gh "api repos/$REPO/compare/*" '' 1 'HTTP 404: Not Found'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  gh_not_called 'pr create *'
}

@test "uses custom source and target branches" {
  export SOURCE_BRANCH="main" TARGET_BRANCH="develop"
  stub_simple_hotfix
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice User main)"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called "api repos/$REPO/compare/develop...main"
  gh_called 'pr create * --base develop *'
  gh_called 'pr create * --head main *'
  [ "$(gh_arg 'pr create *' --title)" = "Sync main into develop" ]
}

# --- 1. Compare --------------------------------------------------------------

@test "does nothing when the source has no new commits" {
  stub_compare "$(compare_json 0 0)"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value outcome)" = "up-to-date" ]
  gh_not_called 'pr *'
}

# --- 2. Skip releases ----------------------------------------------------------

@test "does nothing when only merge commits with no file changes differ" {
  stub_compare "$(compare_json 1 0 "$(commit_json rel111 kurowski User 'Merge pull request #3082 from UCEAP/qa')")"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value outcome)" = "no-file-changes" ]
  gh_not_called 'pr *'
}

# --- 4. Open a PR ----------------------------------------------------------------

@test "opens a PR straight from the source branch to the target branch" {
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called "pr create --repo $REPO *"
  gh_called 'pr create * --base qa *'
  gh_called 'pr create * --head master *'
  [ "$(gh_arg 'pr create *' --title)" = "Sync master into qa" ]
  [ "$(output_value outcome)" = "created" ]
  [ "$(output_value pr_number)" = "500" ]
}

@test "labels the new PR, creating the label if needed" {
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called "label create sync --repo $REPO *"
  gh_called 'pr create * --label sync*'
}

@test "uses a custom label" {
  export LABEL="hotfix-sync"
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called 'pr create * --label hotfix-sync*'
}

@test "lists the hotfix PRs in the PR body" {
  stub_compare "$(compare_json 2 2 "$(commit_json aaa111 alice)" "$(commit_json bbb222 bob)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_gh "api repos/$REPO/commits/bbb222/pulls" "$(pulls_json 102 bob)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  body=$(gh_arg 'pr create *' --body)
  [[ "$body" == *"#101"* ]]
  [[ "$body" == *"#102"* ]]
}

@test "lists directly pushed commits in the PR body" {
  stub_compare "$(compare_json 1 1 "$(commit_json ccc333def carol User 'Emergency config fix')")"
  stub_gh "api repos/$REPO/commits/ccc333def/pulls" '[]'
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  body=$(gh_arg 'pr create *' --body)
  [[ "$body" == *"ccc333d"* ]]
  [[ "$body" == *"Emergency config fix"* ]]
}

@test "warns against rebasing in the PR body" {
  stub_simple_hotfix
  run "$SCRIPT"
  body=$(gh_arg 'pr create *' --body)
  [[ "$body" == *"merge commit"* ]]
}

@test "ignores PRs that were not merged into the source branch" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  # The commit also appears in an open PR against qa; only merged PRs into master count.
  stub_gh "api repos/$REPO/commits/aaa111/pulls" \
    "$(jq -sc 'add' <(pulls_json 90 dave User qa false) <(pulls_json 101 alice))"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  body=$(gh_arg 'pr create *' --body)
  [[ "$body" == *"#101"* ]]
  [[ "$body" != *"#90"* ]]
  gh_not_called 'pr edit * --add-reviewer *dave*'
}

@test "ignores unmerged PRs into the source branch" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  # The commit is also in someone else's still-open PR into master.
  stub_gh "api repos/$REPO/commits/aaa111/pulls" \
    "$(jq -sc 'add' <(pulls_json 95 dave User master false) <(pulls_json 101 alice))"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  body=$(gh_arg 'pr create *' --body)
  [[ "$body" == *"#101"* ]]
  [[ "$body" != *"#95"* ]]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "alice" ]
}

# --- 3. Reuse the open sync PR -------------------------------------------------------

@test "reuses the open sync PR instead of opening another" {
  stub_simple_hotfix
  stub_gh 'pr list *' '[{"number":450,"labels":[{"name":"sync"}]}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr create *'
  [ "$(output_value outcome)" = "updated" ]
  [ "$(output_value pr_number)" = "450" ]
}

@test "looks for an open PR with the same head and base" {
  stub_simple_hotfix
  run "$SCRIPT"
  gh_called "pr list --repo $REPO * --head master *"
  gh_called 'pr list * --base qa *'
  gh_called 'pr list * --state open *'
}

@test "comments on the open sync PR with the newly pushed hotfixes" {
  export BEFORE_SHA="old000"
  stub_gh "api repos/$REPO/compare/old000...master" "$(compare_json 1 1 "$(commit_json bbb222 bob)")"
  stub_compare "$(compare_json 2 2 "$(commit_json aaa111 alice)" "$(commit_json bbb222 bob)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_gh "api repos/$REPO/commits/bbb222/pulls" "$(pulls_json 102 bob)"
  stub_open_pr 450 '[{"name":"sync"}]'
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  body=$(gh_arg 'pr comment 450 *' --body)
  [[ "$body" == *"#102"* ]]
  [[ "$body" != *"#101"* ]]
}

@test "does not comment on the open sync PR when the pushed commits are unknown" {
  stub_simple_hotfix
  stub_open_pr 450 '[{"name":"sync"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr comment *'
}

@test "treats an all-zero BEFORE_SHA as unknown" {
  export BEFORE_SHA="0000000000000000000000000000000000000000"
  stub_simple_hotfix
  stub_open_pr 450 '[{"name":"sync"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called "api repos/$REPO/compare/0000*"
  gh_not_called 'pr comment *'
}

# --- Reviewers -----------------------------------------------------------------------

@test "requests a review from the hotfix PR's author" {
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "alice" ]
}

@test "requests a review from the commit author for a direct push" {
  stub_compare "$(compare_json 1 1 "$(commit_json ccc333 carol)")"
  stub_gh "api repos/$REPO/commits/ccc333/pulls" '[]'
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "carol" ]
}

@test "falls back to the merger when the hotfix PR's author is a bot" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 'dependabot[bot]' Bot)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 103 'dependabot[bot]' Bot)"
  stub_gh "api repos/$REPO/pulls/103" "$(pull_json 103 erin)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "erin" ]
}

@test "falls back to the merger when the hotfix PR's author is the token's account" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 uceap-bot)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 104 uceap-bot)"
  stub_gh "api repos/$REPO/pulls/104" "$(pull_json 104 frank)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "frank" ]
}

@test "requests nobody when a direct push came from a bot" {
  stub_compare "$(compare_json 1 1 "$(commit_json ccc333 'github-actions[bot]' Bot)")"
  stub_gh "api repos/$REPO/commits/ccc333/pulls" '[]'
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr edit * --add-reviewer *'
}

@test "requests nobody when a commit has no GitHub author" {
  stub_compare "$(compare_json 1 1 "$(commit_json ccc333 '')")"
  stub_gh "api repos/$REPO/commits/ccc333/pulls" '[]'
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr edit * --add-reviewer *'
}

@test "requests each person once however many commits they have" {
  stub_compare "$(compare_json 3 2 "$(commit_json aaa111 alice)" "$(commit_json aaa222 alice)" "$(commit_json bbb222 bob)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_gh "api repos/$REPO/commits/aaa222/pulls" "$(pulls_json 101 alice)"
  stub_gh "api repos/$REPO/commits/bbb222/pulls" "$(pulls_json 102 bob)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 500 *' --add-reviewer)" = "alice,bob" ]
}

@test "requests only the authors of newly pushed commits on an open sync PR" {
  export BEFORE_SHA="old000"
  stub_gh "api repos/$REPO/compare/old000...master" "$(compare_json 1 1 "$(commit_json bbb222 bob)")"
  stub_compare "$(compare_json 2 2 "$(commit_json aaa111 alice)" "$(commit_json bbb222 bob)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_gh "api repos/$REPO/commits/bbb222/pulls" "$(pulls_json 102 bob)"
  stub_open_pr 450 '[{"name":"sync"}]'
  stub_mergeable MERGEABLE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_arg 'pr edit 450 *' --add-reviewer)" = "bob" ]
}

@test "requests nobody when request_review is off" {
  export REQUEST_REVIEW="false"
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr edit * --add-reviewer *'
}

@test "still succeeds when a reviewer can't be requested" {
  stub_simple_hotfix
  stub_gh 'pr edit * --add-reviewer *' '' 1 'could not request reviewer'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

# --- 5. Conflicts --------------------------------------------------------------------

@test "labels and comments on a PR with a merge conflict" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable CONFLICTING
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called 'pr edit 500 * --add-label merge-conflict*'
  body=$(gh_arg 'pr comment 500 *' --body)
  [[ "$body" == *"git merge origin/master"* ]]
}

@test "does not repeat the conflict comment when the PR is already labeled" {
  export BEFORE_SHA=""
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_open_pr 450 '[{"name":"sync"},{"name":"merge-conflict"}]'
  stub_mergeable CONFLICTING
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr comment *'
  gh_not_called 'pr edit * --add-label merge-conflict*'
}

@test "does not flag a conflict while GitHub is still computing mergeability" {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable UNKNOWN
  export SYNC_POLL_ATTEMPTS="3"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gh_call_count 'pr view *')" -eq 3 ]
  gh_not_called 'pr edit * --add-label merge-conflict*'
}

# --- 6. Auto-merge -------------------------------------------------------------------

@test "turns on auto-merge with a merge commit when auto_merge is on" {
  export AUTO_MERGE="true"
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_called "pr merge 500 --repo $REPO --auto --merge"
}

@test "leaves auto-merge alone when auto_merge is off" {
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr merge *'
}

@test "warns and succeeds when the repo does not allow auto-merge" {
  export AUTO_MERGE="true"
  stub_simple_hotfix
  stub_gh 'pr merge *' '' 1 'GraphQL: Auto merge is not allowed for this repository'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"auto-merge"* ]]
}

@test "does not turn on auto-merge for a PR with a merge conflict" {
  export AUTO_MERGE="true"
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable CONFLICTING
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  gh_not_called 'pr merge *'
}

# --- 7. Job summary ------------------------------------------------------------------

@test "writes the outcome to the job summary" {
  stub_simple_hotfix
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "pull/500" "$GITHUB_STEP_SUMMARY"
}

@test "writes skipped runs to the job summary" {
  stub_compare "$(compare_json 0 0)"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "up to date" "$GITHUB_STEP_SUMMARY"
}
