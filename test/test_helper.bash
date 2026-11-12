# Shared setup and helpers for the sync_branches tests.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync_branches.sh"

setup() {
  export GH_STUB_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$GH_STUB_DIR/stubs"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  export REPO="UCEAP/example"
  export SOURCE_BRANCH="master"
  export TARGET_BRANCH="qa"
  export LABEL="sync"
  export AUTO_MERGE="false"
  export REQUEST_REVIEW="true"
  export BEFORE_SHA=""
  export SYNC_POLL_ATTEMPTS="1"
  export SYNC_POLL_SECONDS="0"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"

  # The token belongs to the bot account.
  stub_gh 'api user' '{"login":"uceap-bot","type":"User"}'
}

# stub_gh <glob> <stdout> [exit-code] [stderr]
# The most recently registered matching stub wins, so a test can override a
# shared fixture by registering the same pattern again.
stub_gh() {
  local n
  n=$(find "$GH_STUB_DIR/stubs" -name '*.pattern' | wc -l)
  local base
  base=$(printf '%s/%04d' "$GH_STUB_DIR/stubs" "$n")
  printf '%s' "$1" > "$base.pattern"
  printf '%s' "$2" > "$base.out"
  printf '%s' "${3:-0}" > "$base.exit"
  [ -n "${4:-}" ] && printf '%s' "$4" > "$base.err"
  return 0
}

# --- GitHub API fixtures ---------------------------------------------------

# commit_json <sha> <author-login|""> [author-type] [message]
commit_json() {
  local author='null'
  if [ -n "$2" ]; then
    author=$(jq -nc --arg l "$2" --arg t "${3:-User}" '{login:$l,type:$t}')
  fi
  jq -nc --arg sha "$1" --argjson author "$author" --arg msg "${4:-Fix things}" \
    '{sha:$sha, author:$author, commit:{message:$msg, author:{name:"Someone"}}}'
}

# compare_json <ahead_by> <file-count> [commit-json...]
compare_json() {
  local ahead=$1 files=$2
  shift 2
  local commits='[]'
  if [ $# -gt 0 ]; then
    commits=$(printf '%s\n' "$@" | jq -sc '.')
  fi
  jq -nc --argjson ahead "$ahead" --argjson n "$files" --argjson commits "$commits" \
    '{ahead_by:$ahead, files:[range($n) | {filename:"file\(.).php"}], commits:$commits}'
}

# pulls_json <number> <author-login> [author-type] [base-ref] [merged: true|false]
pulls_json() {
  local merged_at='"2026-11-01T00:00:00Z"'
  [ "${5:-true}" = "true" ] || merged_at='null'
  jq -nc --argjson num "$1" --arg l "$2" --arg t "${3:-User}" --arg base "${4:-master}" \
    --argjson merged_at "$merged_at" \
    '[{number:$num, title:"Hotfix \($num)", user:{login:$l,type:$t}, base:{ref:$base}, merged_at:$merged_at}]'
}

# pull_json <number> <merged-by-login>
pull_json() {
  jq -nc --argjson num "$1" --arg m "$2" '{number:$num, merged_by:{login:$m, type:"User"}}'
}

stub_compare() { stub_gh "api repos/$REPO/compare/$TARGET_BRANCH...$SOURCE_BRANCH" "$1"; }
stub_no_open_pr() { stub_gh 'pr list *' '[]'; }
stub_open_pr() { stub_gh 'pr list *' "[{\"number\":$1,\"labels\":${2:-[]}}]"; }
stub_created_pr() { stub_gh 'pr create *' "https://github.com/$REPO/pull/$1"; }
stub_mergeable() { stub_gh 'pr view *' "{\"mergeable\":\"$1\"}"; }

# A new hotfix PR #101 by alice, nothing else going on.
stub_simple_hotfix() {
  stub_compare "$(compare_json 1 1 "$(commit_json aaa111 alice)")"
  stub_gh "api repos/$REPO/commits/aaa111/pulls" "$(pulls_json 101 alice)"
  stub_no_open_pr
  stub_created_pr 500
  stub_mergeable MERGEABLE
}

# --- Assertions on recorded gh calls ---------------------------------------
#
# Patterns assume the script passes `--repo $REPO` straight after the
# subcommand (and PR number), e.g. `gh pr edit 500 --repo UCEAP/x --add-label y`,
# so `pr edit 500 * --add-label y` matches.

calls_log() { cat "$GH_STUB_DIR/calls.log" 2>/dev/null || true; }

# gh_called <glob>: succeeds if any call matches
gh_called() {
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2053
    [[ "$line" == $1 ]] && return 0
  done < <(calls_log)
  echo "expected a gh call matching: $1" >&2
  echo "calls were:" >&2
  calls_log >&2
  return 1
}

gh_not_called() {
  local line
  while IFS= read -r line; do
    # shellcheck disable=SC2053
    if [[ "$line" == $1 ]]; then
      echo "unexpected gh call matching: $1" >&2
      echo "  $line" >&2
      return 1
    fi
  done < <(calls_log)
  return 0
}

gh_call_count() {
  local count=0 line
  while IFS= read -r line; do
    # shellcheck disable=SC2053
    [[ "$line" == $1 ]] && count=$((count + 1))
  done < <(calls_log)
  echo "$count"
}

# gh_arg <call-glob> <flag>: value following <flag> in the first matching call
gh_arg() {
  local n=1 joined args i
  while [ -f "$GH_STUB_DIR/calls/$n" ]; do
    mapfile -d '' args < "$GH_STUB_DIR/calls/$n"
    n=$((n + 1))
    joined="${args[*]}"
    joined="${joined//$'\n'/ }"
    # shellcheck disable=SC2053
    if [[ "$joined" == $1 ]]; then
      for ((i = 0; i < ${#args[@]} - 1; i++)); do
        if [ "${args[$i]}" = "$2" ]; then
          printf '%s' "${args[$((i + 1))]}"
          return 0
        fi
      done
    fi
  done
  return 1
}

output_value() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
