This repository contains reusable workflows for GitHub Actions.

## `sync_branches.yml` — bring hotfixes back from master

Our repos release by merging `qa` into `master`. Hotfixes go straight to `master`, so `master` can end up with commits that `qa` doesn't have. The next `qa` → `master` release PR is then blocked until someone merges `master` back into `qa`, usually in the middle of a release.

`sync_branches.yml` handles this automatically. Run it on every push to `master` and it opens (or updates) a `master` → `qa` pull request right away, so the hotfix comes back to `qa` weeks before the next release instead of during it.

### Usage

Add `.github/workflows/sync_master_to_qa.yml` to the repo:

```yaml
name: Sync master into qa
on:
  push:
    branches: [master]
  workflow_dispatch:
jobs:
  sync:
    uses: UCEAP/actions/.github/workflows/sync_branches.yml@main
    with:
      auto_merge: true
    secrets:
      token: ${{ secrets.BUILD_BOT_PAT }}
```

The `push` trigger runs from the workflow file in the pushed commit, so it only starts working once the caller file has been released to `master`. `workflow_dispatch` works as soon as the file is on the default branch, which is handy for a first manual run.

### Inputs

| Input | Default | Description |
|---|---|---|
| `source_branch` | `master` | The branch to bring changes back from. |
| `target_branch` | `qa` | The branch to bring them into. |
| `auto_merge` | `false` | Turn on auto-merge (merge commit) for the sync PR, so it merges as soon as it's approved and its checks pass. Requires **Settings → General → Allow auto-merge** on the repo. If that setting is off, the workflow logs a warning and leaves the PR for a manual merge. |
| `label` | `sync` | Label added to the sync PR. Created if it doesn't exist. |
| `request_review` | `true` | Request a review from the person behind each hotfix (see [Reviewers](#reviewers)). |
| `actions_ref` | `main` | The `UCEAP/actions` ref to load `scripts/sync_branches.sh` from. Leave it alone; set it to a feature branch only when testing a change to this workflow (see [`test/README.md`](test/README.md)). |

### Secret

| Secret | Description |
|---|---|
| `token` | **Required.** A token for a bot account (we use `uceap-bot` via `BUILD_BOT_PAT`) with `contents: read`, `pull_requests: write` and `issues: write` (for labels) on the repo. A classic token with the `repo` scope covers all three. |

The built-in `GITHUB_TOKEN` won't work. GitHub doesn't run `pull_request` workflows for PRs opened with `GITHUB_TOKEN`, so the target branch's required status checks would never report and the PR could never merge. Using a bot account also means the bot is the PR author, so any developer can approve it.

### What it does

On each run the workflow:

1. **Compares** `target...source`. If `source` has no commits that `target` lacks, it stops.
2. **Skips releases.** If the only difference is merge commits with no file changes, it stops. Every `qa` → `master` release leaves one of these on `master`, and a PR for it would be noise.
3. **Reuses the open sync PR** if there is one. The PR's head *is* the source branch, so new hotfixes show up in it automatically. The workflow only adds a comment listing them and requests the new reviewers.
4. **Otherwise opens a PR** from `source` to `target`, listing the hotfix PRs it brings back, and adds the label.
5. **Flags conflicts.** If GitHub reports the PR can't be merged cleanly, the workflow adds a `merge-conflict` label and comments with the steps in [Conflicts](#conflicts).
6. **Turns on auto-merge** when `auto_merge` is `true`.
7. **Writes a job summary** with what it did.

Runs for the same source and target are serialized, so two hotfixes merged a minute apart can't open duplicate PRs.

### Reviewers

When `request_review` is on, the workflow works out who is behind each new commit on the source branch and requests their review:

1. **The author of the hotfix PR** the commit was merged in with (a PR merged into the source branch).
2. **The commit's author**, when the commit was pushed directly without a PR.
3. **The person who merged the PR**, when the PR's author can't be asked: a bot such as Dependabot, or the token's own account.

Each person is requested once, however many commits they have in the PR. When the sync PR already exists, only the authors of the newly pushed commits are requested. If nobody can be asked, the `sync` label is the only signal.

### Why the PR comes straight from `master`

The sync PR's head is the source branch itself, not a copy of it. Our CI (`build_and_deploy.yml`) and the Claude review skip PRs whose head is `master` or `qa`, because that code has already been through CI on its way in. A PR from an intermediate branch would run the full suite again.

### Merging

**Always merge sync PRs with a merge commit, never rebase.** Rebasing creates new commit IDs on `qa`, so `master` and `qa` drift apart again and the next release hits the same problem. With `auto_merge: true` the workflow already picks the merge-commit method.

### Conflicts

A sync PR's head is `master`, so a conflict can't be fixed in the PR without committing to `master`. Resolve it on a normal branch instead:

```bash
git switch -c sync-master-into-qa origin/qa
git merge origin/master   # resolve conflicts, then commit
git push -u origin sync-master-into-qa
gh pr create --base qa
```

That PR goes through full CI, which is what you want for a real conflict. When it merges, `qa` contains every commit in the sync PR, and GitHub marks the sync PR as merged automatically.
