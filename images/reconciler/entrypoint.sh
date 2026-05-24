#!/usr/bin/env bash
set -eu

: "${GIT_REPO_URL:?GIT_REPO_URL must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${VAULT_SUBPATH:?VAULT_SUBPATH must be set}"

git config --global user.email "${GIT_EMAIL:-content-sync@vps}"
git config --global user.name "${GIT_NAME:-VPS Content Sync}"
git config --global init.defaultBranch main
git config --global --add safe.directory /repo

git config --global credential.helper \
    '!f() { echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'

if [ ! -d "/repo/.git" ]; then
    echo "Initial clone of ${GIT_REPO_URL}"
    git clone "${GIT_REPO_URL}" /repo
fi

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-900}"
WATCH_DIR="/vault/${VAULT_SUBPATH}"
LOCK_DIR="/tmp/sync.lock"

sync_locked() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] sync already in progress; skipping" >&2
        return 0
    fi

    /usr/local/bin/sync-content.sh || echo "[$(date -u +%FT%TZ)] sync failed" >&2
    rmdir "$LOCK_DIR"
}

echo "[$(date -u +%FT%TZ)] initial sync"
sync_locked

(
    while true; do
        sleep "$BACKSTOP_SECONDS"
        echo "[$(date -u +%FT%TZ)] backstop sync"
        sync_locked
    done
) &

pending_pid=
echo "[$(date -u +%FT%TZ)] watching $WATCH_DIR (debounce ${DEBOUNCE_SECONDS}s, backstop ${BACKSTOP_SECONDS}s)"

while read -r _event; do
    if [ -n "${pending_pid:-}" ] && kill -0 "$pending_pid" 2>/dev/null; then
        kill "$pending_pid" 2>/dev/null || true
    fi

    (
        sleep "$DEBOUNCE_SECONDS"
        echo "[$(date -u +%FT%TZ)] debounced sync"
        sync_locked
    ) &
    pending_pid=$!
done < <(
    while true; do
        inotifywait -m -r \
            -e modify,create,delete,move,close_write \
            --exclude '(^|/)\.(obsidian|trash|git)(/|$)' \
            "$WATCH_DIR" \
            || true
        echo "[$(date -u +%FT%TZ)] watcher exited; restarting in 5s" >&2
        sleep 5
    done
)
