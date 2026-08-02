#!/usr/bin/env bash
# install-eurouter-provider.sh — apply the EU Router (eurouter.ai) provider
# patches from oliverhees/hermes-agent onto any hermes-agent installation.
#
# WHY THIS EXISTS
# ----------------
# `~/.hermes/hermes-agent` (the live install `hermes` runs from) tracks
# NousResearch/hermes-agent directly and self-updates via `git pull --ff-only`
# (see hermes_cli/update_cmd.py::_sync_with_upstream_if_needed). A branch that
# has diverged (e.g. carries local EU Router commits) gets its uncommitted
# changes auto-stashed and its branch pointer reset to origin/main — the
# commits themselves survive (recoverable via `git reflog`/orphaned objects),
# but they silently fall out of the checked-out history on every update. This
# script re-applies them — cheap enough to run again after every
# `hermes update` / auto-update, and safe to run repeatedly (skips commits
# that are already present).
#
# WHAT IT DOES
# ------------
# 1. Fetches the `eurouter-provider` branch from oliverhees/hermes-agent
#    (see COMMIT_SUBJECTS below for the exact commit list — the eurouter.ai
#    provider profile + provider_routing threading, the Desktop
#    Settings/onboarding surface, a follow-up fix, and the referral-link
#    update — see that branch's own log for details).
# 2. Cherry-picks each commit onto the target repo's current branch, in
#    order, skipping any whose exact commit subject already exists in the
#    target's history (idempotent — safe to run after every update).
# 3. On a cherry-pick conflict it does NOT guess: it leaves the repo in the
#    normal mid-cherry-pick state (`git cherry-pick --continue`/`--abort`
#    both work) and exits non-zero with the commit that failed.
# 4. Runs a Python syntax check on the touched backend files as a smoke test.
#
# USAGE
#   scripts/install-eurouter-provider.sh [TARGET_DIR]
#   TARGET_DIR defaults to ~/.hermes/hermes-agent.
#
# After it succeeds: restart `hermes desktop` (or run `hermes update` — the
# content-stamp mechanism rebuilds the packaged app automatically) and make
# sure EUROUTER_API_KEY is set in TARGET_DIR's ~/.hermes/.env (this script
# only checks for it and warns; it does not create or edit that file).

set -euo pipefail

FORK_URL="https://github.com/oliverhees/hermes-agent.git"
BRANCH="eurouter-provider"
TARGET_DIR="${1:-$HOME/.hermes/hermes-agent}"

# Commit subjects on $BRANCH, in application order. Matched verbatim against
# `git log --format=%s` in the target repo for idempotency — NOT matched by
# SHA, since cherry-pick always mints a new SHA in the target repo.
COMMIT_SUBJECTS=(
  "Add EU Router provider with EU data-residency routing rules"
  "Surface EU Router in Hermes Desktop and document install/config"
  "EU Router: fix eu_owned default bug, add allow_fallbacks + routing-rule picker"
  "EU Router: use referral link for signup/key CTAs, add cross-device install script"
  "EU Router: register in HERMES_OVERLAYS so --provider/model-switch resolve it"
)
# NOTE: this script's own maintenance commits (e.g. "install script: ...")
# are deliberately NOT listed here — they only touch this file, which has no
# reason to exist inside a target hermes-agent checkout. The matching logic
# below finds these subjects as an in-order SUBSET of the branch's commits,
# skipping anything else (like this script's own history) it encounters
# along the way, rather than requiring an exact commit-for-commit count.

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$TARGET_DIR/.git" ] || die "$TARGET_DIR is not a git repository (pass the hermes-agent install dir as \$1)."

cd "$TARGET_DIR"

if [ -n "$(git status --porcelain)" ]; then
  die "Uncommitted changes in $TARGET_DIR — commit, stash, or discard them first. This script cherry-picks and refuses to run against a dirty tree (an unrelated conflict would be impossible to tell apart from your own WIP)."
fi

log "Fetching $BRANCH from $FORK_URL ..."
git fetch "$FORK_URL" "$BRANCH" --quiet
FETCH_HEAD_SHA="$(git rev-parse FETCH_HEAD)"

# Ordered list of commit SHAs unique to the fetched branch, oldest first —
# i.e. everything from where it diverged from the target's own history up to
# its tip. Deliberately NOT "last N commits": both repos descend from
# NousResearch/hermes-agent, so merge-base finds the true fork point
# regardless of how many commits either side has added since. This means
# COMMIT_SUBJECTS only ever needs a new entry appended, never a count bumped
# alongside it (a past version of this script hardcoded the count and broke
# every time a commit was added to $BRANCH).
MERGE_BASE_SHA="$(git merge-base "$FETCH_HEAD_SHA" HEAD)"
mapfile -t BRANCH_SHAS < <(git log --reverse --format=%H "$MERGE_BASE_SHA..$FETCH_HEAD_SHA")

# Walk the branch's commits in order, matching COMMIT_SUBJECTS as an in-order
# SUBSET (not 1:1) — any branch commit not in the list (this script's own
# maintenance commits, most likely) is silently skipped rather than applied.
applied=0
skipped=0
next_expected=0

# Computed once, matched in-memory below via bash string comparison — NOT
# `git log --format=%s | grep -qxF ...` per commit. That pattern is a classic
# pipefail trap: grep -q exits the instant it finds a match and closes its
# end of the pipe, `git log` then dies mid-write on SIGPIPE, and
# `set -o pipefail` reports that as the pipeline's exit status even though
# grep DID match — silently forcing every "already applied" commit down the
# "Applying" path (and straight into a real cherry-pick conflict against
# already-present content).
existing_subjects="$(git log --format=%s)"

for sha in "${BRANCH_SHAS[@]}"; do
  [ "$next_expected" -lt "${#COMMIT_SUBJECTS[@]}" ] || break
  subject="$(git log -1 --format=%s "$sha")"
  [ "$subject" = "${COMMIT_SUBJECTS[$next_expected]}" ] || continue
  next_expected=$((next_expected + 1))

  if grep -qxF "$subject" <<< "$existing_subjects"; then
    log "Already applied, skipping: $subject"
    skipped=$((skipped + 1))
    continue
  fi

  log "Applying: $subject"
  if ! git cherry-pick "$sha" >/dev/null 2>&1; then
    log ""
    log "Cherry-pick conflict on: $subject"
    log "Resolve it manually (git status shows the conflicted files), then:"
    log "  git add <resolved files> && git cherry-pick --continue"
    log "or 'git cherry-pick --abort' to back out and try again later."
    exit 1
  fi
  applied=$((applied + 1))
done

if [ "$next_expected" -ne "${#COMMIT_SUBJECTS[@]}" ]; then
  die "Only found $next_expected of ${#COMMIT_SUBJECTS[@]} expected commits on $BRANCH (in order) since it diverged from $TARGET_DIR's history. The branch changed shape upstream — update this script's COMMIT_SUBJECTS before re-running."
fi

log ""
log "Applied $applied commit(s), $skipped already present."

log "Syntax-checking touched backend files ..."
python3 - <<'PYEOF'
import ast
files = [
    "agent/agent_init.py",
    "agent/chat_completion_helpers.py",
    "gateway/run.py",
    "tools/delegate_tool.py",
    "providers/base.py",
    "plugins/model-providers/eurouter/__init__.py",
    "hermes_cli/config_defaults.py",
    "hermes_cli/web_server.py",
    "hermes_cli/providers.py",
    "run_agent.py",
]
for f in files:
    with open(f, encoding="utf-8") as fh:
        ast.parse(fh.read(), filename=f)
print(f"  {len(files)} files OK")
PYEOF

log ""
log "Done. Next steps:"
log "  1. Restart 'hermes desktop' (or run 'hermes update') so the packaged"
log "     app picks up the Desktop/settings changes — it rebuilds"
log "     automatically when the content stamp is stale."
if [ -f "$HOME/.hermes/.env" ] && grep -q '^EUROUTER_API_KEY=' "$HOME/.hermes/.env" 2>/dev/null; then
  log "  2. EUROUTER_API_KEY is already set in ~/.hermes/.env — nothing to do."
else
  log "  2. Set EUROUTER_API_KEY in ~/.hermes/.env (not done by this script) —"
  log "     get a key at https://www.eurouter.ai?ref=06ZUHPBK."
fi
