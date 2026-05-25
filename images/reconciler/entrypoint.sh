#!/usr/bin/env bash
set -eu

: "${GIT_REPO_URL:?GIT_REPO_URL must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${VAULT_SUBPATH:?VAULT_SUBPATH must be set}"

# Commit identity
git config --global user.email "${GIT_EMAIL:-content-sync@vps}"
git config --global user.name "${GIT_NAME:-VPS Content Sync}"
git config --global init.defaultBranch main
# Without this, git refuses to operate on /repo when the directory was
# created by a different UID than the process running git (which happens
# on Coolify and other platforms that bind-mount volumes as root).
git config --global --add safe.directory /repo

# PAT-based credential helper. Reads GH_TOKEN from env at request time,
# so the URL doesn't have to embed the token.
git config --global credential.helper \
    '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

# First-run clone if /repo is empty
if [ ! -d "/repo/.git" ]; then
    echo "Initial clone of ${GIT_REPO_URL}"
    git clone "${GIT_REPO_URL}" /repo
fi

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-900}"   # 15 minutes
WATCH_DIR="/vault/${VAULT_SUBPATH}"
LOCK_DIR="/tmp/sync.lock"

# Serialize syncs: only one runs at a time, others skip.
# /tmp is a tmpfs in the container, so the lock can't outlive the process.
sync_locked() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] sync already in progress; skipping" >&2
        return 0
    fi
    /usr/local/bin/sync-content.sh || echo "[$(date -u +%FT%TZ)] sync failed" >&2
    rmdir "$LOCK_DIR"
}

# Wait for the vault subpath to exist before initial sync. On fresh deploys
# the obsidian-sync container takes time to populate the vault; sync-content.sh
# also exits clean when the subpath is missing, but waiting here keeps the
# log readable instead of printing "initial sync" with nothing following.
if [ ! -d "$WATCH_DIR" ]; then
    echo "[$(date -u +%FT%TZ)] $WATCH_DIR not yet present; waiting for obsidian-sync to populate" >&2
    while [ ! -d "$WATCH_DIR" ]; do sleep 10; done
    echo "[$(date -u +%FT%TZ)] $WATCH_DIR ready" >&2
fi

# Initial sync to converge on whatever state is on disk right now.
echo "[$(date -u +%FT%TZ)] initial sync"
sync_locked

# Slow polling backstop — runs in the background regardless of watcher state.
# If inotify dies, drops events, or never sees changes for some reason,
# this still catches them eventually.
(
    while true; do
        sleep "$BACKSTOP_SECONDS"
        echo "[$(date -u +%FT%TZ)] backstop sync"
        sync_locked
    done
) &

# Debounced inotify watcher — the fast path.
# Resets a pending sync each time an event arrives; fires when the
# filesystem has been quiet for DEBOUNCE_SECONDS.
pending_pid=
echo "[$(date -u +%FT%TZ)] watching $WATCH_DIR (debounce ${DEBOUNCE_SECONDS}s, backstop ${BACKSTOP_SECONDS}s)"

while read -r _event; do
    # Cancel any pending debounced sync
    if [ -n "${pending_pid:-}" ] && kill -0 "$pending_pid" 2>/dev/null; then
        kill "$pending_pid" 2>/dev/null || true
    fi

    # Schedule a new one
    (
        sleep "$DEBOUNCE_SECONDS"
        echo "[$(date -u +%FT%TZ)] debounced sync"
        sync_locked
    ) &
    pending_pid=$!
done < <(
    while true; do
        # Don't invoke inotifywait when the directory isn't there — it
        # prints "Couldn't watch" to stderr and exits, leaving us in a tight
        # retry loop spamming the log. Wait quietly for it to appear instead.
        # Handles both fresh-deploy populate-time and (unlikely) mid-operation
        # directory disappearance.
        if [ ! -d "$WATCH_DIR" ]; then
            echo "[$(date -u +%FT%TZ)] $WATCH_DIR not present; waiting" >&2
            while [ ! -d "$WATCH_DIR" ]; do sleep 10; done
            echo "[$(date -u +%FT%TZ)] $WATCH_DIR appeared; starting watch" >&2
        fi

        inotifywait -m -r \
            -e modify,create,delete,move,close_write \
            --exclude '(^|/)(drafts|\.(obsidian|trash|git))(/|$)' \
            "$WATCH_DIR" \
            || true
        echo "[$(date -u +%FT%TZ)] watcher exited; restarting in 5s" >&2
        sleep 5
    done
)
