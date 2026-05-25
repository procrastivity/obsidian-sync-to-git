#!/bin/sh
set -eu

VAULT="${VAULT_PATH:-/vault}"
REPO="${REPO_PATH:-/repo}"
SUBPATH="${VAULT_SUBPATH:?VAULT_SUBPATH must be set}"
BRANCH="${GIT_BRANCH:-main}"

# Bail clean if the vault subpath isn't there yet. Happens during initial
# deploy (obsidian-sync is still populating the vault) or if the subpath
# disappears mid-operation. Callers (initial sync, backstop, debounced sync)
# all get a clean exit rather than a noisy rsync failure.
if [ ! -d "$VAULT/$SUBPATH" ]; then
    exit 0
fi

cd "$REPO"

# Empty-repo bootstrap: a freshly-cloned content repo with no commits yet
# needs a branch to exist before we can stage and commit. Idempotent — the
# rev-parse succeeds after the first commit lands.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    git checkout -B "$BRANCH"
fi

# Update the remote-tracking ref so the "push when ahead but no diff" check
# below has a current view of origin. Failure is non-fatal — first run has
# no remote ref yet, and transient network issues shouldn't block the sync.
git fetch origin "$BRANCH:refs/remotes/origin/$BRANCH" || true

push_branch() {
    if ! git push origin "$BRANCH" 2>/dev/null; then
        echo "fast-forward failed; attempting force-with-lease" >&2
        git push --force-with-lease origin "$BRANCH"
    fi
}

# 1. Reconcile working tree with vault subpath.
#    --exclude='.git' is critical: target is the repo root, not a subdir,
#    so without this rsync --delete would clobber .git on every run.
#    --exclude='drafts' keeps work-in-progress out of the content repo by
#    convention; see `09-handoff-blog-template.md` for the author workflow.
#    --exclude='.github' protects the per-repo GitHub Action workflow (which
#    lives only in the content repo, not the vault) from being deleted by
#    --delete. --exclude='README*' and --exclude='LICENSE*' do the same for
#    those common repo-root files.
rsync -a --delete \
    --exclude='.obsidian' \
    --exclude='.trash' \
    --exclude='.git' \
    --exclude='.github' \
    --exclude='drafts' \
    --exclude='README*' \
    --exclude='LICENSE*' \
    "$VAULT/$SUBPATH/" "$REPO/"

# 2. If rsync produced no working-tree changes, we might still have
#    stranded local commits to push (e.g., a previous push failed due to
#    transient network issues). Drain those, then exit.
git add -A
if git diff --staged --quiet; then
    if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
        && [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
        push_branch
    fi
    exit 0
fi

# 3. Commit and push the working-tree changes.
git commit -m "sync $(date -u +%FT%TZ)"

push_branch
