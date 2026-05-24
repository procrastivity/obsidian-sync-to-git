# Hand-off: VPS Content Sync Setup (Multi-Repo Variant)

> Sibling of `06-handoff-vps-content-sync-docker.md`. Same Docker Compose foundation and same `ob` headless sync, but content lives in **per-site content repos** with one reconciler service per repo, authenticating to GitHub via a Personal Access Token instead of per-repo deploy keys.

## Status

Designed, not yet built. Architecture decisions inherited from the chat that produced `05` and `06`; this doc is the multi-repo (Pattern B) variant.

## When to pick this over `06`

`06` is "one content repo, multi-site, path-filtered Actions." `07` is "one repo per site, simpler Actions, more reconcilers." Pick `07` when:

- You want each site's content to be a self-contained repo — its own history, its own permissions, its own backup story, its own size envelope.
- You'd rather GitHub Actions stay dumb (one per repo, no path filters) and trade that simplicity for slightly more repos to manage.
- You expect site count to grow over time and want adding a site to be mechanical (new env block, new service, new repo — done).

Pick `06` when:

- You'd rather have one repo to browse, back up, and reason about.
- You're certain the site count is stable and small.
- The single-deploy-key auth pattern feels lighter to you than PAT management.

The two patterns aren't mutually exclusive — nothing stops you from running a `06`-style stack for a group of small landings and a `07`-style stack for the active blog sites, on the same VPS. But picking one to start is the simpler default.

## The pipeline at a glance

```
Obsidian on phone/laptop/iPad
        │
        │  (Obsidian Sync, end-to-end encrypted)
        ▼
obsidian-sync container running `ob sync --continuous`
        │
        │  (files land in the shared `vault` volume)
        ▼
┌───────────────────────────┬───────────────────────────┐
│                           │                           │
▼                           ▼                           ▼
reconciler-A                reconciler-B                reconciler-N
(syncs sites/site-a/        (syncs sites/site-b/        ...
 to site-a-content repo)     to site-b-content repo)
        │                           │
        │ git push                  │ git push
        ▼                           ▼
GitHub: site-a-content      GitHub: site-b-content      ...
        │                           │
        │ push fires Action         │ push fires Action
        ▼                           ▼
Pages Deploy Hook (A)       Pages Deploy Hook (B)       ...
        │                           │
        ▼                           ▼
site-a builds & deploys     site-b builds & deploys     ...
```

End-to-end latency is the same as `06` (~1–3 minutes). The fan-out is now structural rather than logical: each push only ever affects one content repo, so each push only ever triggers one Pages build by definition. No path filters needed.

## What changes vs. `06`

Three substantive changes; everything else is structurally identical.

**Auth: deploy keys → fine-grained PAT.** A single fine-grained Personal Access Token scoped to all the per-site content repos replaces N per-repo deploy keys. (GitHub rejects the same SSH public key being added as a deploy key on multiple repos, so N repos with SSH would mean N keypairs plus SSH config aliases — workable but fiddly.) The `ssh-keys/` directory and SSH config go away entirely. Git pushes happen over HTTPS using a credential helper that injects the token at request time.

**Reconciler: one service per content repo.** The compose file grows a `reconciler-<site>` service per content repo, each parameterized with its own `GIT_REPO_URL`, `VAULT_SUBPATH`, and named volume for the git working tree.

**Rsync target: repo root, not a subdirectory.** Since each content repo *is* a single site, the reconciler rsyncs from `$VAULT/sites/<site>/` into the repo root, not into a `sites/<site>/` subdirectory. The reconciler script gains a `--exclude='.git'` so it doesn't clobber the working tree's git metadata.

## Project layout

```
content-sync-vps/
├── docker-compose.yml
├── .env                        # gitignored (PAT and per-site repo URLs)
├── .env.example
├── .gitignore
├── README.md
├── obsidian-sync/
│   └── Dockerfile
└── reconciler/
    ├── Dockerfile
    ├── entrypoint.sh
    └── sync-content.sh
```

`.gitignore`:

```
.env
```

No `ssh-keys/` directory in this version — that's the auth simplification PAT buys you.

## The compose file

```yaml
services:
  obsidian-sync:
    build:
      context: ./obsidian-sync
      args:
        PUID: ${PUID:-1000}
        PGID: ${PGID:-1000}
    restart: unless-stopped
    volumes:
      - vault:/home/obsidian/vault
      - ob-config:/home/obsidian/.config/obsidian

  reconciler-procrastivity:
    build:
      context: ./reconciler
      args:
        PUID: ${PUID:-1000}
        PGID: ${PGID:-1000}
    restart: unless-stopped
    depends_on:
      - obsidian-sync
    environment:
      - GIT_REPO_URL=${PROCRASTIVITY_REPO_URL}
      - VAULT_SUBPATH=sites/procrastivity-fm
      - GH_TOKEN=${GH_TOKEN}
      - GIT_EMAIL=${GIT_EMAIL:-content-sync@vps}
      - GIT_NAME=${GIT_NAME:-VPS Content Sync}
      - DEBOUNCE_SECONDS=${DEBOUNCE_SECONDS:-5}
      - BACKSTOP_SECONDS=${BACKSTOP_SECONDS:-900}
    volumes:
      - vault:/vault:ro
      - procrastivity-repo:/repo

  reconciler-dabblegangers:
    build:
      context: ./reconciler
      args:
        PUID: ${PUID:-1000}
        PGID: ${PGID:-1000}
    restart: unless-stopped
    depends_on:
      - obsidian-sync
    environment:
      - GIT_REPO_URL=${DABBLEGANGERS_REPO_URL}
      - VAULT_SUBPATH=sites/dabblegangers
      - GH_TOKEN=${GH_TOKEN}
      - GIT_EMAIL=${GIT_EMAIL:-content-sync@vps}
      - GIT_NAME=${GIT_NAME:-VPS Content Sync}
      - DEBOUNCE_SECONDS=${DEBOUNCE_SECONDS:-5}
      - BACKSTOP_SECONDS=${BACKSTOP_SECONDS:-900}
    volumes:
      - vault:/vault:ro
      - dabblegangers-repo:/repo

  # Add a new reconciler-<site> block per content repo.

volumes:
  vault:
  ob-config:
  procrastivity-repo:
  dabblegangers-repo:
  # Add a new named volume per content repo.
```

Adding a 10th site is: one new entry in `.env`, one new service block, one new named volume — perhaps 15 lines of YAML.

## `.env.example`

```
# Host UID/GID
PUID=1000
PGID=1000

# Fine-grained PAT with content:write scope on each per-site content repo.
# Treat as a secret.
GH_TOKEN=github_pat_...

# Per-site content repo URLs (HTTPS form)
PROCRASTIVITY_REPO_URL=https://github.com/OWNER/procrastivity-content.git
DABBLEGANGERS_REPO_URL=https://github.com/OWNER/dabblegangers-content.git

# Commit identity for automated commits
GIT_EMAIL=content-sync@vps
GIT_NAME=VPS Content Sync

# Debounce: how long the filesystem must be quiet before a sync fires
DEBOUNCE_SECONDS=5

# Backstop: how often to force a sync regardless of file events (insurance
# against inotify drops, filesystem oddities, or silently missed changes)
BACKSTOP_SECONDS=900
```

## The obsidian-sync image

`obsidian-sync/Dockerfile`:

```dockerfile
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @obsidianmd/headless

ARG PUID=1000
ARG PGID=1000
RUN groupadd -g ${PGID} obsidian \
 && useradd -u ${PUID} -g obsidian -m -s /bin/bash obsidian

USER obsidian
WORKDIR /home/obsidian/vault

CMD ["ob", "sync", "--continuous"]
```

Cross-check the npm package name against the [obsidianmd/obsidian-headless README](https://github.com/obsidianmd/obsidian-headless) at build time — the team has been iterating since launch.

## The reconciler image

`reconciler/Dockerfile`:

```dockerfile
FROM alpine:3.20

# git brings in ca-certificates transitively, which we need for HTTPS to GitHub.
# No openssh-client: this variant authenticates with a PAT over HTTPS, not SSH.
# inotify-tools provides inotifywait for the file-watcher entrypoint.
RUN apk add --no-cache \
    git \
    rsync \
    bash \
    inotify-tools

ARG PUID=1000
ARG PGID=1000
RUN addgroup -g ${PGID} obsidian \
 && adduser -D -u ${PUID} -G obsidian -s /bin/bash obsidian

COPY sync-content.sh /usr/local/bin/sync-content.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/sync-content.sh /usr/local/bin/entrypoint.sh

USER obsidian
WORKDIR /repo

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

The two scripts that get copied in:

`reconciler/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -eu

# Commit identity
git config --global user.email "${GIT_EMAIL:-content-sync@vps}"
git config --global user.name "${GIT_NAME:-VPS Content Sync}"

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

while read -r event; do
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
        inotifywait -m -r \
            -e modify,create,delete,move,close_write \
            --exclude '(^|/)\.(obsidian|trash|git)(/|$)' \
            "$WATCH_DIR" \
            || true
        echo "[$(date -u +%FT%TZ)] watcher exited; restarting in 5s" >&2
        sleep 5
    done
)
```

Three details worth pointing at:

- **The credential helper line.** It tells git to call back into the shell whenever it needs credentials, and the callback echoes the username/password pair using the `GH_TOKEN` env var. The token never appears in URLs or log output.
- **The lock dir (`mkdir`/`rmdir`).** `mkdir` is atomic on POSIX filesystems — it succeeds for exactly one caller when there's a race. This serializes syncs cleanly: if a backstop sync fires while a debounced sync is mid-flight, the second one just skips. No double-pushing, no overlapping rsyncs into the same git working tree.
- **The watcher restart loop.** If `inotifywait` exits for any reason (kernel quirk, watch exhaustion, signal), the loop sleeps 5 seconds and restarts it. The script never gets stuck waiting on a dead watcher. Combined with the backstop, even an inotify subsystem that's completely broken doesn't stop syncs from happening — they just fall back to the 15-minute cadence until the watcher recovers.

`bash` instead of `sh` is deliberate: the process substitution (`< <(...)`) keeps the `while read` loop in the parent shell so `pending_pid` survives across iterations. Alpine's `bash` package is already installed in the image.

`reconciler/sync-content.sh`:

```sh
#!/bin/sh
set -eu

VAULT="${VAULT_PATH:-/vault}"
REPO="${REPO_PATH:-/repo}"
SUBPATH="${VAULT_SUBPATH:?VAULT_SUBPATH must be set}"

cd "$REPO"

# 1. Reconcile working tree with vault subpath.
#    --exclude='.git' is critical: target is the repo root, not a subdir,
#    so without this rsync --delete would clobber .git on every run.
rsync -a --delete \
    --exclude='.obsidian' \
    --exclude='.trash' \
    --exclude='.git' \
    "$VAULT/$SUBPATH/" "$REPO/"

# 2. Exit clean if nothing changed
git add -A
git diff --staged --quiet && exit 0

# 3. Commit
git commit -m "sync $(date -u +%FT%TZ)"

# 4. Fetch so --force-with-lease has a current lease
git fetch origin main

# 5. Fast-forward push first; fall back to force-with-lease on divergence
if ! git push origin main 2>/dev/null; then
    echo "fast-forward failed; attempting force-with-lease" >&2
    git push --force-with-lease origin main
fi
```

## Tuning the watcher

Two env vars control the file-watcher behavior:

- **`DEBOUNCE_SECONDS`** (default 5) — how long the filesystem must be quiet before a sync fires. Long enough that an Obsidian Sync burst (which can deliver dozens of files in a couple seconds when a device comes online) settles into one commit, short enough that publish-to-live latency is dominated by the build rather than the debounce. Five seconds is a sweet spot; tune up if you see burst-induced double commits, tune down if 5s feels laggy.
- **`BACKSTOP_SECONDS`** (default 900, i.e. 15 minutes) — how often the entrypoint forces a sync regardless of whether file events have fired. Insurance against inotify dropping events, the kernel watch limit being hit, the watcher process dying, or any other failure mode where the fast path stops working silently. Even if the watcher is completely broken, content is at most `BACKSTOP_SECONDS` stale.

The two work together: the watcher is the fast path (typical latency: `DEBOUNCE_SECONDS` + sync time), the backstop is the slow but guaranteed path. Most syncs come from the watcher; the backstop's job is to make sure the system is still correct in the rare cases the watcher isn't.

Reasonable tuning ranges:

| Use case | DEBOUNCE_SECONDS | BACKSTOP_SECONDS |
|----------|------------------|------------------|
| Default | 5 | 900 |
| Tight latency, accept noise | 2 | 300 |
| Quiet logs, batch-friendly | 10 | 1800 |

## PAT setup

In GitHub: **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.

Configure:

- **Resource owner:** your user account (or the org that owns the content repos).
- **Repository access:** **Only select repositories**, then check every per-site content repo. Adding a new site later means coming back here and adding the new repo to the token's scope.
- **Permissions:** Repository permissions → **Contents: Read and write**. No other permissions needed.
- **Expiration:** the maximum GitHub allows for fine-grained tokens (currently capped at 1 year). Calendar a reminder ~2 weeks before to rotate.

Copy the token immediately on creation (GitHub only shows it once). Put it in `.env` as `GH_TOKEN`.

## Setup walkthrough

The differences from `06` are concentrated in the auth setup; the rest of the flow is the same shape.

### 1. Prepare the project directory

```sh
git clone <your-repo-of-this-compose-project> content-sync-vps
cd content-sync-vps
cp .env.example .env
$EDITOR .env   # fill in GH_TOKEN, per-site repo URLs, PUID/PGID
```

### 2. Create the per-site content repos on GitHub

One repo per site. They can be empty — the reconciler will clone whatever's there (including an empty repo) on first run and start pushing into it.

### 3. Generate the PAT

Per the PAT setup section above. Scope it to every content repo. Paste the token into `.env`.

### 4. Build the images

```sh
docker compose build
```

### 5. One-time `ob` authentication

The trickiest step. Needs interactive access to set up the vault binding and credentials. `docker compose run --rm` opens a one-shot container with TTY support:

```sh
docker compose run --rm obsidian-sync ob login
docker compose run --rm obsidian-sync ob sync-list-remote
docker compose run --rm obsidian-sync ob sync-setup \
    --vault "Your Vault Name" \
    --path /home/obsidian/vault
docker compose run --rm obsidian-sync ob sync-config --mode pull-only
docker compose run --rm obsidian-sync ob sync-config --config ""
docker compose run --rm obsidian-sync ob sync
```

Pull-only mode and disabling config syncing are both load-bearing — see "Things to watch for." Initial `ob sync` pulls the vault state down; this can take a while depending on vault size.

Credentials land in the `ob-config` named volume and persist across container restarts. You only do this once.

### 6. Bring up the stack

```sh
docker compose up -d
docker compose logs -f
```

You'll see one log stream per reconciler service plus the obsidian-sync daemon. On first iteration of each reconciler, it does the initial clone of its content repo into its named volume, then enters the reconciliation loop.

### 7. End-to-end smoke test

From Obsidian on a real device, create `sites/SITE-NAME/posts/test-vps-sync.md`, save. Watch:

```sh
docker compose logs -f obsidian-sync
docker compose logs -f reconciler-SITE-NAME
```

Within ~60s of the file landing on the VPS, the matching reconciler commits and pushes to that site's content repo. Action/webhook fires, Pages builds, post is live.

Delete the file in Obsidian; confirm propagation removes it.

## Coolify integration

Roughly the same shape as `06`:

1. Push the project to a git repo Coolify can read (everything except `.env`).
2. **Add Resource → Docker Compose**, point at the repo.
3. Set env vars via Coolify's UI: `GH_TOKEN`, each per-site `*_REPO_URL`, `PUID`, `PGID`, etc.
4. Deploy.

The pleasant simplification here vs. `06`: no SSH keys to provision. PAT is just another env var. Coolify's secret management handles it natively.

The interactive `ob login` constraint is unchanged — that still requires SSH-and-`docker exec`. One-time pain.

## GitHub-side configuration

Significantly simpler than `06` because there's no path-filter cleverness to maintain.

### Per-site content repo: one of two approaches

**Option 1 — GitHub Action (recommended).** Each content repo has `.github/workflows/build.yml`:

```yaml
name: Trigger Pages build
on:
  push:
    branches: [main]
jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - name: Hit Pages deploy hook
        run: curl -X POST -f "${{ secrets.PAGES_DEPLOY_HOOK }}"
```

Identical across every content repo. Branch filter is in the workflow, so non-main branches won't trigger builds — useful if you ever want a `drafts` branch convention later.

**Option 2 — Repository Webhook.** In the content repo: **Settings → Webhooks → Add webhook**, paste the Pages Deploy Hook URL, content type `application/json`, events: "Just the push event." No workflow file needed.

Slightly simpler (zero files), slightly less flexible (no branch filtering — any push to any branch fires the hook). For pure-main workflows it's fine. The Action approach is the safer default.

### Pages Deploy Hooks

Each Pages project has its Deploy Hook URL in the Cloudflare dashboard (**Project → Settings → Builds & deployments → Deploy hooks → Create deploy hook**). Store it as a repo secret (`PAGES_DEPLOY_HOOK`) in each content repo if using the Action approach, or paste directly into the webhook URL if using approach 2. Treat the URLs as secrets — they're unauthenticated, so anyone with the URL can trigger a build.

### Site-repo side: `fetch-content.sh`

The script gets simpler — no sparse checkout needed since each content repo is just this site:

```sh
#!/usr/bin/env sh
set -e
rm -rf content
git clone \
  --depth 1 \
  "https://${CONTENT_REPO_TOKEN}@github.com/OWNER/SITE-content.git" \
  content
```

`CONTENT_REPO_TOKEN` here is a separate PAT (or the same one, if you scope it broadly enough) configured as a Pages environment variable for that site project. Read-only is sufficient on the Pages-side PAT; the VPS-side PAT needs write.

Astro content collection points at `content/posts/` (or wherever within the content repo your post files live).

## Recovery

When a reconciler's git working tree gets into a state you don't understand (corruption, interrupted operation, mysterious failures), recovery in this variant is structural rather than scripted: blow away the named volume, restart the container, and the entrypoint's first-run logic re-clones from GitHub.

To reset a single reconciler:

```sh
# Stop the container holding the bad working tree.
docker compose stop reconciler-SITE

# Remove its named volume. The exact volume name is `<project>_<volume>`,
# e.g. `content-sync-vps_procrastivity-repo`. Confirm with `docker volume ls`.
docker volume rm content-sync-vps_procrastivity-repo

# Bring it back up. The entrypoint sees no .git in /repo and re-clones.
docker compose up -d reconciler-SITE
```

Downtime for that one site: ~5 seconds plus the re-clone time (small for a posts-only repo). The vault and other reconcilers are untouched.

For a full reset (rare — covers "everything is broken, start over for all sites"):

```sh
docker compose down
docker volume rm content-sync-vps_procrastivity-repo \
                 content-sync-vps_dabblegangers-repo
# Do NOT remove `vault` or `ob-config` unless you specifically want
# to re-bootstrap Obsidian Sync; those hold durable state worth
# preserving across reconciler resets.
docker compose up -d
```

The convergent reconciliation pattern (rsync vault → working tree, commit, push) means the system self-heals from blank state on the next iteration. There's no separate "fix it" script to maintain — the recovery procedure *is* the entrypoint logic.

## Things to watch for

- **PAT expiration is a calendar item.** Fine-grained tokens cap at 1 year. Set a calendar reminder for ~2 weeks before expiry to rotate the token and update `GH_TOKEN` in `.env` (or Coolify). When the token expires unannounced, every reconciler starts failing pushes at the same time — recoverable but annoying.
- **Adding a new site updates the PAT scope.** When you create a new content repo, the existing PAT can't push to it until you go back into the token's settings and add the new repo to its allowed list. Easy to forget; the failure mode is `fatal: Authentication failed` in that reconciler's logs.
- **`--exclude='.git'` in the rsync is load-bearing.** Without it, the reconciler would delete the working tree's `.git` directory on every run, leaving the repo in a corrupted state. The recovery procedure (covered above) restores from such corruption, but the exclude prevents the problem from arising.
- **Pull-only mode is still load-bearing.** Same reason as `05`/`06`: prevents accidental writes on the VPS from propagating back to your real devices.
- **Per-site backups are easier now.** Each content repo can be backed up independently. GitHub itself is the primary backup; an occasional `git clone --mirror` to offsite storage for each repo gives belt-and-suspenders coverage.
- **One credential helper, N reconcilers.** All reconciler containers source from the same image, which means they all have the same credential helper config. The `GH_TOKEN` env var is what scopes each container's access — and it's the same token in all of them. If you ever want different tokens per reconciler (different scopes, different rotation cadences), it's a per-service `GH_TOKEN` env override and works trivially. Probably overkill for personal use.
- **inotify on Docker volumes works fine in normal setups but isn't universal.** Named volumes on local filesystems (ext4, xfs, overlayfs) propagate events cleanly. NFS-backed volumes and some FUSE-based volume drivers silently see no events. First symptom of trouble: "watching $WATCH_DIR" log lines on startup, but no "debounced sync" entries follow file changes, and only "backstop sync" entries appear. If that happens, the backstop is still keeping you correct — you're just on the slow path.
- **`fs.inotify.max_user_watches` is a host-level kernel limit.** Default 8192 on most Linux distros. A large vault with thousands of subdirectories could exhaust it. Symptom: `inotifywait` exits with `Failed to watch ...; upper limit on inotify watches reached`. Fix: increase via `sysctl -w fs.inotify.max_user_watches=524288` on the host (and persist in `/etc/sysctl.conf`). Worth knowing exists; unlikely to hit at personal-blog scale.
- **The watcher uses `close_write` events** alongside the obvious `modify`/`create`/`delete`/`move`. This catches the "file landed fully and was closed" moment cleanly. Doesn't fire on every keystroke during atomic writes that use temp-file + rename (rename produces `move` events, which we also watch). Net: Obsidian Sync's writes show up as one event per file, not dozens.
- **Lock-skipping is not lock-queuing.** If a sync is in flight and an event arrives, the new event's debounced sync skips instead of waiting. Safe because the in-flight sync uses convergent rsync semantics — it picks up whatever's on disk at the moment it runs. The only edge case is a burst right at the tail end of an in-flight sync's rsync window that lands in neither sync. The backstop catches that within `BACKSTOP_SECONDS`.

## Monitoring

Same shape as `06`. Per-reconciler log inspection (`docker compose logs reconciler-SITE`) is enough for ad-hoc checking. For "find out within a day if it broke," a host-level cron grepping the journal or compose logs for failure patterns is plenty.

Slightly nicer with multi-reconciler: a Healthchecks.io check per reconciler. Each reconciler pings its own check URL after a successful loop iteration; if any of them goes silent, you get a notification scoped to that specific site. Easy to wire into the entrypoint loop.

## What this doesn't solve

- **VPS down = publishing down.** Unchanged from `05`/`06`.
- **PAT expiration is a recurring chore.** GitHub Apps remove the expiration ceiling but cost more upfront setup. Probably worth it if you find yourself rotating PATs more than once.
- **Initial `ob login` requires interactive access.** Same as `06`.
- **No per-site auth isolation.** All reconcilers share one PAT; a compromise of the VPS gives access to all content repos. Same blast radius as a deploy-keys-everywhere setup, just consolidated.

## Open questions

- **One PAT, or one per reconciler?** Default is one shared. Switching to per-service tokens is trivial and meaningful only if you want per-site rotation cadence or to limit blast radius. Probably not for v1.
- **GitHub App as the long-term replacement for PAT.** Worth a closer look once you're confident in the architecture and want to stop rotating tokens. Out of scope for initial build.
- **Site-repo `CONTENT_REPO_TOKEN`: same PAT, or a separate read-only one?** Both work. Separate read-only is the more careful default (Pages builds shouldn't have write access to content repos), and the read-only PAT can be the maximum-lifetime fine-grained token without much rotation risk.
- **Should `obsidian-sync` and the reconcilers share an image base?** They don't right now — `obsidian-sync` is `node:22-slim`, reconciler is `alpine:3.20`. Different base images means more disk and slower first build. Not a real cost at any reasonable size; flagged here only because future-you might be tempted to "consolidate" and remember it was a deliberate choice (the reconciler genuinely doesn't need Node).

## Hand-off Doc Index

- `01-triage.md` — master overview, stack decisions, site bucketing
- `02-handoff-skeleton.md` — the Astro skeleton template repo, spin-up flow
- `03-handoff-content-sync.md` — the content sync architecture chat (Options A/B/C)
- `04-deferred-topics.md` — running backlog
- `05-handoff-vps-content-sync.md` — VPS content sync via host-level systemd (Pattern A, single repo)
- `06-handoff-vps-content-sync-docker.md` — VPS content sync via Docker Compose (Pattern A, single repo)
- `07-handoff-vps-content-sync-multi-repo.md` — this doc; Docker Compose, Pattern B (per-site repos)
