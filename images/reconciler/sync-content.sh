#!/bin/sh
set -eu

VAULT="${VAULT_PATH:-/vault}"
REPO="${REPO_PATH:-/repo}"
SUBPATH="${VAULT_SUBPATH:?VAULT_SUBPATH must be set}"
BRANCH="${GIT_BRANCH:-main}"

cd "$REPO"

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    git checkout -B "$BRANCH"
fi

git fetch origin "$BRANCH:refs/remotes/origin/$BRANCH" || true

push_branch() {
    if ! git push origin "$BRANCH" 2>/dev/null; then
        echo "fast-forward failed; attempting force-with-lease" >&2
        git push --force-with-lease origin "$BRANCH"
    fi
}

rsync -a --delete \
    --exclude='.obsidian' \
    --exclude='.trash' \
    --exclude='.git' \
    --exclude='.github' \
    --exclude='drafts' \
    --exclude='README*' \
    --exclude='LICENSE*' \
    "$VAULT/$SUBPATH/" "$REPO/"

git add -A
if git diff --staged --quiet; then
    if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
        && [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
        push_branch
    fi
    exit 0
fi

git commit -m "sync $(date -u +%FT%TZ)"

push_branch
