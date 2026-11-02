# kattakath/.github

The shared landing system for every public repo in the fleet: **one required check
(`gate`), the full suite run once per PR, and auto-merge through GitHub Merge Queue where
GitHub offers one.**

## What's here

| Path | What it is |
|---|---|
| `actions/gate` | Composite action. Fails unless every job the caller's `gate` job needs ended **exactly** as expected: `success` where it should run, `skipped` where it shouldn't. |
| `.github/workflows/auto-merge.yml` | Reusable. Arms squash auto-merge on same-repo, non-draft, non-Dependabot PRs, using a GitHub App token. |
| `.github/workflows/arm-dependabot.yml` | Reusable. Arms Dependabot PRs from a schedule. A Dependabot-triggered run can't read the App key. |
| `rulesets/main.json`, `rulesets/merge-queue.json` | The default-branch ruleset: squash only, `gate` required (from GitHub Actions only), admin bypass. Plus the queue rule. |
| `scripts/apply-ruleset.sh` | Makes a repo match the ruleset. Dry run by default. |

## The two tiers

GitHub offers a merge queue only on **public repos owned by an organization**. The tier is
derived from that, never chosen by hand:

| Tier | Repos | The heavy suite runs | Landing |
|---|---|---|---|
| A | org-owned + public | once, in the merge queue (`vars.QUEUE_ENABLED == 'true'`) | merge queue |
| B | everything else | once, on the PR | auto-merge |

Fork PRs run the heavy suite on the PR in both tiers. A contributor sees a real failure
before review, not a queue ejection that only a maintainer can retry.

## Adopting it in a repo

```yaml
on:
  pull_request:
  merge_group:
    types: [checks_requested]
  workflow_dispatch:
concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}   # never cancel a queue run
permissions:
  contents: read            # no secrets in CI: merge_group runs fork code in base-repo context
jobs:
  quick:                    # optional, cheap, never required
    if: github.event_name == 'pull_request'
  heavy:                    # the repo's real suite; any number of jobs with this if:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository || vars.QUEUE_ENABLED != 'true'
  gate:                     # THE ONLY REQUIRED CHECK; never rename it
    if: ${{ !cancelled() }}
    needs: [quick, heavy]
    runs-on: ubuntu-24.04
    steps:
      - uses: kattakath/.github/actions/gate@<sha>
        with:
          needs: ${{ toJSON(needs) }}
          # A deliberate second copy of heavy's if:. If the two copies drift, gate goes red.
          expect: >-
            {"quick": ${{ github.event_name == 'pull_request' }},
             "heavy": ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository || vars.QUEUE_ENABLED != 'true' }}}
```

Then:
1. Add the `auto-merge` and `arm-dependabot` callers. Each reusable file's header has the snippet.
2. Merge that PR under the repo's current rules.
3. Run `scripts/apply-ruleset.sh OWNER/REPO` and read the diff, then re-run with `--apply`.
   - On Tier A it sets `QUEUE_ENABLED` only after the queue rule exists.
   - It refuses to replace a ruleset that requires checks other than `gate`.
4. Open WIP PRs as **drafts**. `gate` goes green on a PR in seconds, so an armed PR is queued at once.

## Why this shape

- **Measured gain:** on kattakath/skills the heavy suite ran twice per PR (~96 s on the PR,
  ~101 s again on `push: main`). Under the queue it runs once: #174 ran 84 s in `merge_group`,
  and its PR run skipped it.
- **Why an aggregator:** "A job that is skipped will report its status as Success" (GitHub
  docs), so a skippable job must never be the required check. Prior art: indexmap,
  DeterminateSystems/magic-nix-cache-action. The rejected alternative was skipping the
  required job itself (boinkor/governor). It's fragile once that job gains a `needs:`.
- **The ejection is proven:** kattakath/skills #175 failed in the queue, and the queue
  removed it unmerged.

MIT licensed.
