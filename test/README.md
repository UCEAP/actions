# Tests

## Unit tests

`sync_branches.yml` keeps its logic in `scripts/sync_branches.sh` so it can be tested without GitHub. The tests in `sync_branches.bats` put a fake `gh` (`stubs/gh`) first on `PATH`. The fake returns canned GitHub API responses and records every call, so each test can check what the script would have done.

```bash
npx --yes bats@1.11.1 test
```

`.github/workflows/test.yml` runs these tests and ShellCheck on every PR, and actionlint on the workflows each PR adds or changes. Touching an existing workflow means fixing its actionlint findings too.

## End-to-end check

The unit tests can't prove the GitHub side works: tokens, required checks, auto-merge, review requests. Before merging a change to `sync_branches.yml`, run it for real against throwaway branches.

1. Push the change to a branch of this repo, e.g. `my-change`.
2. In a test repo, create two branches from the same commit: `sync-test-src` and `sync-test-dst`.
3. Add a temporary caller there that points at your branch:

   ```yaml
   name: Sync test
   on: workflow_dispatch
   jobs:
     sync:
       uses: UCEAP/actions/.github/workflows/sync_branches.yml@my-change
       with:
         source_branch: sync-test-src
         target_branch: sync-test-dst
         actions_ref: my-change
         auto_merge: true
       secrets:
         token: ${{ secrets.BUILD_BOT_PAT }}
   ```

4. Run it from the **Actions** tab after each step, and check the result:

   | Step | Expected |
   |---|---|
   | Run with nothing changed | Job summary says up to date. No PR. |
   | Merge `sync-test-dst` into `sync-test-src` with `--no-ff` and an empty diff | Summary says no file changes. No PR. |
   | Merge a small PR into `sync-test-src` | Sync PR opened by the bot, labeled `sync`, with that PR's author requested and auto-merge on. |
   | Merge a second PR into `sync-test-src` | No new PR. The open one gets a comment and its author is requested. |
   | Commit a conflicting change to `sync-test-dst`, then a change to the same line on `sync-test-src` | Sync PR gets `merge-conflict` and a comment with the resolution steps. |

5. Delete the test branches, the caller file and any leftover PRs.
