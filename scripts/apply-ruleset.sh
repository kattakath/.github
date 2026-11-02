#!/usr/bin/env bash
# Make one repo's default-branch ruleset match rulesets/main.json (plus merge-queue.json when
# the repo can have a queue), and set the repo settings the landing flow needs.
#
#   scripts/apply-ruleset.sh OWNER/REPO            # dry run: print the diff, change nothing
#   scripts/apply-ruleset.sh OWNER/REPO --apply    # write it
#
# Tier is DERIVED, never passed: GitHub offers a merge queue only on a public repo owned by an
# organization ("available in any public repository owned by an organization", docs). So:
#   Tier A (org + public)  -> ruleset + merge_queue rule, then vars.QUEUE_ENABLED=true
#   Tier B (anything else) -> ruleset only, vars.QUEUE_ENABLED removed
# ORDER MATTERS on Tier A: the queue rule must exist BEFORE QUEUE_ENABLED, or own-branch PRs
# skip the heavy suite with nothing left to run it.
#
# Refuses to replace a ruleset whose required checks are not exactly [gate]: replacing it
# would silently drop checks that repo still relies on. Move those under `gate` first.
set -euo pipefail

repo=${1:?usage: apply-ruleset.sh OWNER/REPO [--apply]}
apply=false
[ "${2:-}" = "--apply" ] && apply=true
here=$(cd "$(dirname "$0")/.." && pwd)

meta=$(gh api "repos/$repo" --jq '{owner: .owner.type, visibility, default: .default_branch}')
owner_type=$(jq -r .owner <<<"$meta")
visibility=$(jq -r .visibility <<<"$meta")
default=$(jq -r .default <<<"$meta")
if [ "$owner_type" = Organization ] && [ "$visibility" = public ]; then tier=A; else tier=B; fi
echo "$repo: owner=$owner_type visibility=$visibility default=$default -> tier $tier"

if [ "$tier" = A ]; then
  desired=$(jq --slurpfile q "$here/rulesets/merge-queue.json" '.rules += $q' "$here/rulesets/main.json")
else
  desired=$(jq . "$here/rulesets/main.json")
fi

# The existing ruleset, matched by what it TARGETS, not by name (repos use main, protect-main,
# "main protection"). Two matches is ambiguous; stop rather than guess.
ids=$(gh api "repos/$repo/rulesets?includes_parents=false" --paginate --jq '.[] | select(.target == "branch") | .id')
match=()
for id in $ids; do
  inc=$(gh api "repos/$repo/rulesets/$id" --jq '.conditions.ref_name.include // [] | join(" ")')
  case " $inc " in
    *" ~DEFAULT_BRANCH "* | *" refs/heads/$default "* | *" ~ALL "*) match+=("$id") ;;
  esac
done
if [ "${#match[@]}" -gt 1 ]; then
  echo "error: ${#match[@]} rulesets target $default (${match[*]}); merge them by hand first" >&2
  exit 2
fi

# Drops the defaults the API adds on read, so an unchanged ruleset diffs clean.
norm='{name, enforcement, conditions, bypass_actors: (.bypass_actors // [] | map({actor_id, actor_type, bypass_mode})),
  rules: (.rules | map(if .type == "pull_request" then .parameters |= (del(.required_reviewers | select(. == [])) | del(.dismissal_restriction | select(.enabled == false and .allowed_actors == []))) else . end) | sort_by(.type))}'
if [ "${#match[@]}" -eq 1 ]; then
  id=${match[0]}
  current=$(gh api "repos/$repo/rulesets/$id")
  checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | sort' <<<"$current")
  if [ "$checks" != '[]' ] && [ "$checks" != '["gate"]' ]; then
    echo "error: ruleset $id requires $checks; move them under a 'gate' job before replacing it" >&2
    exit 3
  fi
  echo "--- current ruleset $id"; echo "+++ desired"
  if diff <(jq -S "$norm" <<<"$current") <(jq -S "$norm" <<<"$desired"); then echo "(ruleset already matches)"; fi
else
  id=
  echo "no ruleset targets $default; would create:"; jq -S "$norm" <<<"$desired"
fi

if ! $apply; then echo "dry run: nothing changed (re-run with --apply)"; exit 0; fi

gh api -X PATCH "repos/$repo" -F allow_auto_merge=true -F allow_squash_merge=true \
  -F delete_branch_on_merge=true --jq '"settings: auto_merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete_branch=\(.delete_branch_on_merge)"'
if [ -n "$id" ]; then
  gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$desired" --jq '"updated ruleset \(.id): \([.rules[].type] | join(","))"'
else
  gh api -X POST "repos/$repo/rulesets" --input - <<<"$desired" --jq '"created ruleset \(.id): \([.rules[].type] | join(","))"'
fi
if [ "$tier" = A ]; then
  gh variable set QUEUE_ENABLED -R "$repo" --body true && echo "set QUEUE_ENABLED=true"
else
  if gh variable delete QUEUE_ENABLED -R "$repo" 2>/dev/null; then echo "removed QUEUE_ENABLED"; fi
fi
