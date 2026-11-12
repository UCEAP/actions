#!/usr/bin/env bash
# Open or update a pull request that brings SOURCE_BRANCH back into
# TARGET_BRANCH (by default master -> qa). Used by
# .github/workflows/sync_branches.yml; behaviour is documented in README.md.
#
# Environment:
#   REPO              owner/name (required)
#   GH_TOKEN          token for gh; must not be GITHUB_TOKEN (see README)
#   SOURCE_BRANCH     default master
#   TARGET_BRANCH     default qa
#   LABEL             default sync
#   AUTO_MERGE        true|false, default false
#   REQUEST_REVIEW    true|false, default true
#   BEFORE_SHA        source branch tip before this push; empty if unknown
#   SYNC_POLL_ATTEMPTS, SYNC_POLL_SECONDS  mergeability polling (default 10 x 3s)
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY     set by GitHub Actions
set -euo pipefail

: "${REPO:?REPO must be set to owner/name}"
SOURCE_BRANCH="${SOURCE_BRANCH:-master}"
TARGET_BRANCH="${TARGET_BRANCH:-qa}"
LABEL="${LABEL:-sync}"
AUTO_MERGE="${AUTO_MERGE:-false}"
REQUEST_REVIEW="${REQUEST_REVIEW:-true}"
BEFORE_SHA="${BEFORE_SHA:-}"
POLL_ATTEMPTS="${SYNC_POLL_ATTEMPTS:-10}"
POLL_SECONDS="${SYNC_POLL_SECONDS:-3}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

CONFLICT_LABEL="merge-conflict"
DOCS_URL="https://github.com/UCEAP/actions#sync_branchesyml--bring-hotfixes-back-from-master"

# An all-zero SHA means the branch was just created: no usable "before".
if [[ "$BEFORE_SHA" =~ ^0+$ ]]; then
  BEFORE_SHA=""
fi

warn() { echo "::warning::$*"; }
summary() { printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; }

finish() {
  local outcome=$1 message=$2 pr_number=${3:-}
  echo "outcome=$outcome" >> "$GITHUB_OUTPUT"
  echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
  summary "### Sync \`$SOURCE_BRANCH\` into \`$TARGET_BRANCH\`"
  summary ""
  summary "$message"
  echo "$message"
  exit 0
}

# --- GitHub lookups ----------------------------------------------------------

TOKEN_USER=$(gh api user 2>/dev/null | jq -r '.login // empty' || true)

declare -A PR_CACHE=()

# The PR (number, title, user) that merged <sha> into the source branch, or "null".
pr_for_commit() {
  local sha=$1
  if [ -z "${PR_CACHE[$sha]+set}" ]; then
    PR_CACHE[$sha]=$(gh api "repos/$REPO/commits/$sha/pulls" | jq -c --arg base "$SOURCE_BRANCH" \
      '[.[] | select(.base.ref == $base and .merged_at != null)] | first // null
       | if . == null then null else {number, title, user} end')
  fi
  printf '%s' "${PR_CACHE[$sha]}"
}

# Whether a {login, type} user can be asked for a review.
reviewable() {
  local login type
  login=$(jq -r '.login // empty' <<< "$1")
  type=$(jq -r '.type // empty' <<< "$1")
  [ -n "$login" ] && [ "$type" != "Bot" ] && [[ "$login" != *"[bot]" ]] && [ "$login" != "$TOKEN_USER" ]
}

# The person to ask about one commit (JSON from the compare API), or nothing.
reviewer_for_commit() {
  local commit=$1 sha pr user merger
  sha=$(jq -r '.sha' <<< "$commit")
  pr=$(pr_for_commit "$sha")
  if [ "$pr" = "null" ]; then
    user=$(jq -c '.author // {}' <<< "$commit")
    reviewable "$user" && jq -r '.login' <<< "$user"
    return 0
  fi
  user=$(jq -c '.user // {}' <<< "$pr")
  if reviewable "$user"; then
    jq -r '.login' <<< "$user"
    return 0
  fi
  merger=$(gh api "repos/$REPO/pulls/$(jq -r '.number' <<< "$pr")" | jq -c '.merged_by // {}')
  reviewable "$merger" && jq -r '.login' <<< "$merger"
  return 0
}

# Comma-separated, de-duplicated reviewers for a JSON array of commits.
reviewers_for() {
  local commit login
  local -a logins=()
  while IFS= read -r commit; do
    login=$(reviewer_for_commit "$commit")
    if [ -n "$login" ] && [[ " ${logins[*]} " != *" $login "* ]]; then
      logins+=("$login")
    fi
  done < <(jq -c '.[]' <<< "$1")
  (IFS=,; printf '%s' "${logins[*]}")
}

# Markdown list of the hotfix PRs (or direct commits) in a JSON array of commits.
hotfix_list() {
  local commit sha pr number line
  local -a seen=()
  while IFS= read -r commit; do
    sha=$(jq -r '.sha' <<< "$commit")
    pr=$(pr_for_commit "$sha")
    if [ "$pr" = "null" ]; then
      echo "- \`${sha:0:7}\` $(jq -r '.commit.message | split("\n")[0]' <<< "$commit") (pushed directly)"
      continue
    fi
    number=$(jq -r '.number' <<< "$pr")
    [[ " ${seen[*]} " == *" $number "* ]] && continue
    seen+=("$number")
    line="- #$number $(jq -r '.title' <<< "$pr") (@$(jq -r '.user.login' <<< "$pr"))"
    echo "$line"
  done < <(jq -c '.[]' <<< "$1")
}

ensure_label() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" > /dev/null 2>&1 || true
}

# --- 1-2. Compare --------------------------------------------------------------

compare=$(gh api "repos/$REPO/compare/$TARGET_BRANCH...$SOURCE_BRANCH")
ahead=$(jq -r '.ahead_by' <<< "$compare")
if [ "$ahead" -eq 0 ]; then
  finish up-to-date "\`$TARGET_BRANCH\` is up to date with \`$SOURCE_BRANCH\`. Nothing to sync."
fi
if [ "$(jq '.files | length' <<< "$compare")" -eq 0 ]; then
  finish no-file-changes "\`$SOURCE_BRANCH\` is $ahead commit(s) ahead of \`$TARGET_BRANCH\` but changes no files (a release merge). Nothing to sync."
fi
all_commits=$(jq -c '.commits' <<< "$compare")

new_commits=""
if [ -n "$BEFORE_SHA" ]; then
  new_commits=$(gh api "repos/$REPO/compare/$BEFORE_SHA...$SOURCE_BRANCH" | jq -c '.commits')
fi

# --- 3-4. Find or open the sync PR -------------------------------------------------

existing=$(gh pr list --repo "$REPO" --base "$TARGET_BRANCH" --head "$SOURCE_BRANCH" --state open \
  --json number,labels | jq -c 'first // null')

if [ "$existing" != "null" ]; then
  outcome=updated
  pr_number=$(jq -r '.number' <<< "$existing")
  labels=$(jq -r '[.labels[].name] | join(" ")' <<< "$existing")
  review_commits="${new_commits:-$all_commits}"
  if [ -n "$new_commits" ] && [ "$(jq 'length' <<< "$new_commits")" -gt 0 ]; then
    comment="New on \`$SOURCE_BRANCH\`, now included in this PR:"$'\n\n'"$(hotfix_list "$new_commits")"
    gh pr comment "$pr_number" --repo "$REPO" --body "$comment" > /dev/null
  fi
else
  outcome=created
  labels=""
  review_commits="$all_commits"
  ensure_label "$LABEL" 0E8A16 "Brings $SOURCE_BRANCH back into $TARGET_BRANCH"
  body=$(cat <<EOF
Brings these changes from \`$SOURCE_BRANCH\` back into \`$TARGET_BRANCH\`, so the next \`$TARGET_BRANCH\` → \`$SOURCE_BRANCH\` release isn't blocked:

$(hotfix_list "$all_commits")

**Merge with a merge commit, never rebase.** Rebasing gives these commits new IDs on \`$TARGET_BRANCH\`, so the branches drift apart again.

New commits on \`$SOURCE_BRANCH\` show up here automatically until this PR is merged.

_Opened automatically by [sync_branches]($DOCS_URL)._
EOF
)
  url=$(gh pr create --repo "$REPO" --base "$TARGET_BRANCH" --head "$SOURCE_BRANCH" \
    --title "Sync $SOURCE_BRANCH into $TARGET_BRANCH" --body "$body" --label "$LABEL")
  pr_number="${url##*/}"
fi
pr_url="https://github.com/$REPO/pull/$pr_number"

# --- Reviewers -------------------------------------------------------------------

if [ "$REQUEST_REVIEW" = "true" ]; then
  reviewers=$(reviewers_for "$review_commits")
  if [ -n "$reviewers" ]; then
    gh pr edit "$pr_number" --repo "$REPO" --add-reviewer "$reviewers" > /dev/null \
      || warn "Could not request a review from $reviewers on $pr_url."
  fi
fi

# --- 5. Conflicts --------------------------------------------------------------------

mergeable=UNKNOWN
for ((attempt = 1; attempt <= POLL_ATTEMPTS; attempt++)); do
  mergeable=$(gh pr view "$pr_number" --repo "$REPO" --json mergeable | jq -r '.mergeable // "UNKNOWN"')
  [ "$mergeable" != "UNKNOWN" ] && break
  [ "$attempt" -lt "$POLL_ATTEMPTS" ] && sleep "$POLL_SECONDS"
done

if [ "$mergeable" = "CONFLICTING" ] && [[ " $labels " != *" $CONFLICT_LABEL "* ]]; then
  ensure_label "$CONFLICT_LABEL" B60205 "Needs a manual merge to resolve conflicts"
  gh pr edit "$pr_number" --repo "$REPO" --add-label "$CONFLICT_LABEL" > /dev/null
  gh pr comment "$pr_number" --repo "$REPO" --body "$(cat <<EOF
This PR has a merge conflict. Its head is \`$SOURCE_BRANCH\`, so it can't be fixed here. Resolve it on a normal branch instead:

\`\`\`bash
git switch -c sync-$SOURCE_BRANCH-into-$TARGET_BRANCH origin/$TARGET_BRANCH
git merge origin/$SOURCE_BRANCH   # resolve conflicts, then commit
git push -u origin sync-$SOURCE_BRANCH-into-$TARGET_BRANCH
gh pr create --base $TARGET_BRANCH
\`\`\`

When that PR merges, GitHub marks this one as merged automatically. See [Conflicts]($DOCS_URL).
EOF
)" > /dev/null
fi

# --- 6. Auto-merge ---------------------------------------------------------------------

if [ "$AUTO_MERGE" = "true" ] && [ "$mergeable" != "CONFLICTING" ]; then
  gh pr merge "$pr_number" --repo "$REPO" --auto --merge > /dev/null \
    || warn "Could not turn on auto-merge for $pr_url. Is \"Allow auto-merge\" enabled in the repo settings? Merge it by hand with a merge commit."
fi

# --- 7. Summary --------------------------------------------------------------------------

message="Sync PR $outcome: $pr_url"
[ "$mergeable" = "CONFLICTING" ] && message="$message (has a merge conflict)"
finish "$outcome" "$message" "$pr_number"
