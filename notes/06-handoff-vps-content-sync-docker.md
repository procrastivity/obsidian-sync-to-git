# Hand-off: VPS Content Sync Setup (Docker Compose variant)

> Sibling to `05-handoff-vps-content-sync.md`. Same architecture (Obsidian headless sync + reconciliation script + git push), packaged as a Docker Compose project instead of host-level systemd services. Pick this one if you want everything Coolify-managed under one deployment model; pick `05` if you'd rather keep content sync infra entirely separate from application deployments.

## Status

Designed, not yet built. Architecture decisions inherited from the chat that produced `05`; this doc just re-packages the same pieces.

## The pipeline at a glance

Identical to the systemd version:

```
Obsidian on phone/laptop/iPad
        │
        │  (Obsidian Sync, end-to-end encrypted)
        ▼
obsidian-sync container running `ob sync --continuous`
        │
        │  (files land in the shared `vault` volume)
        ▼
content-reconciler container looping every 60s
        │
        │  (rsync vault → git working tree, commit, push)
        ▼
Content repo on GitHub
        │
        │  (push fires path-filtered GitHub Action)
        ▼
Cloudflare Pages Deploy Hook (one per site)
        │
        │  (Pages clones site repo, fetches content, builds)
        ▼
Site live on CDN
```

End-to-end latency: same ~1–3 minutes as the systemd version.

## When to pick this version over systemd

- **You want everything under Coolify.** Coolify deploys Docker Compose projects natively. This pattern slots in as just another app. Your content sync pipeline gets the same redeploy / restart / log-viewing experience as everything else.
- **You'd rather declare than configure.** `docker-compose.yml` + two small Dockerfiles is more legible than four systemd unit files scattered in `/etc/systemd/system/`.
- **You expect to move VPSes.** Docker Compose projects port to a new host with a `docker compose up -d`. systemd setups need the unit files re-installed, paths fixed, packages reinstalled.

The trade-offs:

- **Initial `ob login` is awkward.** Requires `docker compose run --rm` with a TTY, which is fine over SSH but ugly through Coolify's UI.
- **Updates rebuild images.** `npm install -g obsidian-headless@latest` on the host is replaced with bumping the Dockerfile and rebuilding. Slightly more ceremony.
- **One more layer to debug through.** Volume permissions, container networking, image rebuild quirks. If you're already comfortable in Docker, fine; if you're not, host-level systemd has a lower floor.

## Project layout

A self-contained directory you can commit to a git repo and point Coolify at:

```
content-sync-vps/
├── docker-compose.yml
├── .env                        # gitignored (secrets, repo URL)
├── .env.example                # template
├── .gitignore
├── README.md
├── images/
│   ├── obsidian-sync/
│   │   └── Dockerfile
│   └── reconciler/
│       ├── Dockerfile
│       ├── entrypoint.sh
│       └── sync-content.sh
└── ssh-keys/                   # gitignored (deploy key)
    ├── config
    ├── id_ed25519
    ├── id_ed25519.pub
    └── known_hosts
```

`.gitignore` should at minimum cover:

```
.env
ssh-keys/
```

## The compose file

`docker-compose.yml`:

```yaml
services:
  obsidian-sync:
    build:
      context: ./images/obsidian-sync
    restart: unless-stopped
    volumes:
      - vault:/home/obsidian/vault
      - ob-config:/home/obsidian/.config/obsidian-headless

  content-reconciler:
    build:
      context: ./images/reconciler
    restart: unless-stopped
    depends_on:
      - obsidian-sync
    environment:
      - GIT_REPO_URL=${GIT_REPO_URL}
      - GIT_EMAIL=${GIT_EMAIL:-content-sync@vps}
      - GIT_NAME=${GIT_NAME:-VPS Content Sync}
      - SLEEP_INTERVAL=${SLEEP_INTERVAL:-60}
    volumes:
      - vault:/vault:ro
      - content-repo:/repo
      - ./ssh-keys:/home/obsidian/.ssh:ro

volumes:
  vault:
  ob-config:
  content-repo:
```

Notes:

- **Vault is shared between containers.** Mounted read-write into `obsidian-sync` (it writes via `ob`), read-only into `content-reconciler` (it only reads via rsync). The `:ro` on the reconciler's mount is the actual safety mechanism preventing the reconciler from mutating vault state — it's not belt-and-suspenders to a (nonexistent) pull-only mode; it's the only enforcement.
- **User/permission model.** The implemented images bake in UID/GID 1000. Published-image deployments can override runtime UID/GID with Compose's `user: "${PUID:-1000}:${PGID:-1000}"`; local-build examples do not use PUID/PGID build args anymore.
- **No exposed ports.** Neither container needs network ingress; both only make outbound connections (to Obsidian Sync servers and GitHub).
- **Named volumes for state.** `vault`, `ob-config`, `content-repo` all survive container rebuilds. The `ssh-keys/` directory is a host bind-mount so you can manage the key files outside Docker's volume namespace.

## `.env.example`

Committed to the repo as a template; `.env` itself is gitignored.

```
# Host UID/GID — used by published-image compose files with a runtime `user:`.
# The local-build image snippets below bake in 1000:1000.
PUID=1000
PGID=1000

# Content repo to push to
GIT_REPO_URL=git@github.com:OWNER/content-repo.git

# Commit identity for automated commits
GIT_EMAIL=content-sync@vps
GIT_NAME=VPS Content Sync

# Reconciliation interval in seconds
SLEEP_INTERVAL=60
```

## The obsidian-sync image

`images/obsidian-sync/Dockerfile`:

```dockerfile
FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g obsidian-headless

RUN mkdir -p /home/obsidian/vault /home/obsidian/.config/obsidian-headless \
 && chown -R node:node /home/obsidian \
 && chmod -R a+rwX /home/obsidian

ENV HOME=/home/obsidian

USER node
WORKDIR /home/obsidian/vault

CMD ["ob", "sync", "--continuous"]
```

Cross-check the npm package name against the [obsidianmd/obsidian-headless README](https://github.com/obsidianmd/obsidian-headless) at build time — the team has been iterating.

## The reconciler image

`images/reconciler/Dockerfile`:

```dockerfile
FROM alpine:3.23

RUN apk add --no-cache \
    git \
    openssh-client \
    rsync \
    bash

RUN addgroup -g 1000 obsidian \
 && adduser -D -u 1000 -G obsidian -s /bin/bash obsidian \
 && mkdir -p /repo /home/obsidian \
 && chown -R obsidian:obsidian /repo /home/obsidian \
 && chmod -R a+rwX /repo /home/obsidian

COPY sync-content.sh /usr/local/bin/sync-content.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/sync-content.sh /usr/local/bin/entrypoint.sh

USER obsidian
WORKDIR /repo

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

`reconciler/entrypoint.sh`:

```sh
#!/bin/sh
set -eu

# Configure git identity from env
git config --global user.email "${GIT_EMAIL:-content-sync@vps}"
git config --global user.name "${GIT_NAME:-VPS Content Sync}"

# First-run clone if the repo volume is empty
if [ ! -d "/repo/.git" ]; then
    echo "Initial clone of ${GIT_REPO_URL}"
    git clone "${GIT_REPO_URL}" /repo
fi

INTERVAL="${SLEEP_INTERVAL:-60}"
echo "Starting reconciliation loop (interval: ${INTERVAL}s)"

while true; do
    if ! /usr/local/bin/sync-content.sh; then
        echo "Reconciliation failed; will retry next interval" >&2
    fi
    sleep "${INTERVAL}"
done
```

`reconciler/sync-content.sh`:

```sh
#!/bin/sh
set -eu

VAULT="${VAULT_PATH:-/vault}"
REPO="${REPO_PATH:-/repo}"

cd "$REPO"

# 1. Make working tree match vault on disk
rsync -a --delete \
    --exclude='.obsidian' \
    --exclude='.trash' \
    "$VAULT/sites/" "$REPO/sites/"

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

Behavior is identical to the systemd version's `sync-content.sh`; only the paths differ. The loop in `entrypoint.sh` replaces what was systemd's `OnUnitActiveSec=60s` timer.

## SSH key setup

The reconciler container needs the deploy key inside it. The cleanest pattern is generating the key on the host, in the project directory, and bind-mounting it.

From inside `content-sync-vps/`:

```sh
mkdir -p ssh-keys
ssh-keygen -t ed25519 -f ssh-keys/id_ed25519 -C "vps-content-sync" -N ""

# Pre-populate known_hosts so SSH doesn't prompt
ssh-keyscan github.com > ssh-keys/known_hosts

# Lock permissions (must match the container user; implemented images use 1000:1000)
chmod 700 ssh-keys
chmod 600 ssh-keys/id_ed25519
chmod 644 ssh-keys/id_ed25519.pub ssh-keys/known_hosts
chown -R 1000:1000 ssh-keys  # match container user
```

`ssh-keys/config`:

```
Host github.com
  HostName github.com
  User git
  IdentityFile /home/obsidian/.ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile /home/obsidian/.ssh/known_hosts
```

`chmod 600 ssh-keys/config`.

Add the public key (`ssh-keys/id_ed25519.pub`) as a deploy key on the GitHub content repo: **Settings → Deploy keys → Add deploy key**, paste, **check "Allow write access"**, save.

## Setup walkthrough

Roughly:

### 1. Prepare the project directory

```sh
git clone <your-repo-of-this-compose-project> content-sync-vps
cd content-sync-vps
cp .env.example .env
$EDITOR .env   # fill in GIT_REPO_URL
```

If you haven't created the project repo yet, just create the directory locally and commit later.

### 2. Generate the deploy key

Per the section above. Add the public key to the GitHub content repo with write access.

### 3. Build the images

```sh
docker compose build
```

### 4. One-time `ob` authentication

The trickiest step. Needs interactive access to set up the vault binding and credentials. `docker compose run` is the entry point:

```sh
docker compose run --rm obsidian-sync ob login
# Prompts for email, password, 2FA
```

The credentials land in the `ob-config` named volume and persist across container restarts.

```sh
docker compose run --rm obsidian-sync ob sync-list-remote
# Note the vault name to use below

docker compose run --rm obsidian-sync ob sync-setup \
    --vault "Your Vault Name" \
    --path /home/obsidian/vault

docker compose run --rm obsidian-sync ob sync-config \
    --path /home/obsidian/vault --configs ""
```

Disabling config category syncing (the `--configs ""` line; note the plural) keeps theme/plugin/workspace state from being pulled down to a machine that won't render notes. Earlier revisions of this doc also included `ob sync-config --mode pull-only` here; that flag doesn't exist on the bare `ob` CLI — see "Things to watch for" for what the actual safety story is.

### 5. Initial sync

```sh
docker compose run --rm obsidian-sync ob sync
```

Takes a while; depends on vault size. Verify with:

```sh
docker compose run --rm obsidian-sync ls /home/obsidian/vault/sites/
```

### 6. Bring up the stack

```sh
docker compose up -d
docker compose logs -f
```

You should see `obsidian-sync` running `ob sync --continuous` and `content-reconciler` running the entrypoint loop. The reconciler will do its initial clone of the content repo on first iteration.

### 7. End-to-end smoke test

From Obsidian on a real device, create `sites/SITE-NAME/posts/test-vps-sync.md`, save. Then on the host:

```sh
# Confirm Obsidian Sync delivered the file:
docker compose logs -f obsidian-sync

# Confirm reconciler picked it up within ~60s:
docker compose logs -f content-reconciler
# Look for "sync <timestamp>" commit log
```

GitHub Action fires, Deploy Hook fires, Pages build runs, post is live.

Delete the test file from Obsidian on the same device; confirm the deletion propagates all the way through.

## Coolify integration

Coolify supports Docker Compose deployments as a first-class application type. The setup pattern:

1. Push this project (everything except `.env` and `ssh-keys/`) to a git repo Coolify can read.
2. In Coolify: **Add Resource → Docker Compose**, point at the repo.
3. Set the environment variables (`GIT_REPO_URL`, etc.) through Coolify's UI rather than committing a `.env`.
4. For the SSH keys: Coolify exposes per-application persistent storage. Create a persistent storage entry, populate it with the keys (via Coolify's file manager or SSH to the host), and bind-mount it as `/home/obsidian/.ssh` in the reconciler service.
5. Deploy. Coolify handles `docker compose up -d` and restarts.

The one step Coolify doesn't help with is the interactive `ob login` — you still have to SSH to the host and `docker compose exec` (or `docker exec`) into the obsidian-sync container to run it. After that initial setup, the auth state lives in the `ob-config` volume and persists across Coolify-managed redeploys.

## GitHub-side configuration

Identical to `05`. See that doc's "GitHub-side configuration" section for:

- Per-site workflow file at `.github/workflows/build-SITE-NAME.yml` with path-filtered trigger
- Pages Deploy Hook URLs stored as GitHub secrets in the content repo
- Site repo's `fetch-content.sh` that does sparse, shallow clone at build time
- `CONTENT_REPO_TOKEN` PAT for site repos to authenticate against the (private) content repo

None of that changes between systemd and Docker versions of the VPS side.

## Things to watch for

- **Pull-only sync mode isn't actually configured.** Earlier revisions of this doc claimed `ob sync-config --mode pull-only` was load-bearing for safety; that flag doesn't exist on bare `obsidian-headless`. The actual mechanism keeping VPS-side mutations from propagating back to your devices is structural: the reconciler container has the vault mounted `:ro` (so it physically cannot write), and nothing else writes to the vault except `ob sync --continuous` itself (which only relays remote state). If you want explicit pull-only enforcement, swap the `obsidian-sync` service for [Belphemur's image](https://github.com/Belphemur/obsidian-headless-sync-docker), which exposes `SYNC_MODE=pull-only` via env var.
- **The `ob-config` volume holds your Obsidian Sync credentials.** If the volume gets blown away (accidental `docker compose down -v` — note the `-v`), you'll need to `ob login` again. Worth a periodic backup of the volume to offsite storage. `docker run --rm -v content-sync-vps_ob-config:/data -v $(pwd):/backup alpine tar czf /backup/ob-config.tar.gz -C /data .` style.
- **SSH key ownership must match the container user.** The implemented local-build images use UID/GID 1000, so `./ssh-keys/` should be readable by 1000:1000 unless your compose file explicitly overrides the runtime user.
- **The reconciler's read-only vault mount is the actual safety enforcement.** Since pull-only sync mode isn't really available on bare `obsidian-headless`, the `:ro` mount is what physically prevents the reconciler from mutating vault state. Don't drop it.
- **Image updates need rebuilds.** When `ob` updates, you bump the Dockerfile (or just `docker compose build --no-cache obsidian-sync` to pick up the latest from npm) and `docker compose up -d obsidian-sync`. Track the upstream project occasionally for breaking changes.
- **`docker compose down -v` is destructive.** The `-v` flag wipes named volumes, which means losing your vault, your `ob` credentials, and the git working tree all at once. Re-bootstrapping is possible (re-login, re-sync) but takes time. There's no real reason to use `-v` in this project; aliasing yourself to forget it exists is fine.
- **Pages Deploy Hooks don't expire.** Once created, they live forever unless deleted. Treat the URLs as secrets — they're unauthenticated.

## Monitoring

Cheapest version: `docker compose logs --tail 100 content-reconciler` periodically, or have a host-level cron job tail-and-grep the logs for failure markers and ping a notification service when it finds them.

Slightly more involved: add a healthcheck to the reconciler container that touches a file each successful loop iteration; have an external monitor (Healthchecks.io, Pushover via cron) verify the file's mtime is recent.

For a personal blog, "I'll find out within a day if it broke" is plenty. Don't build dashboards.

## What this doesn't solve

- **VPS down = publishing down.** Identical to systemd version: Obsidian Sync between devices keeps working (it's hosted by Obsidian), but new content doesn't reach the site until the VPS is back. Reconciler catches up naturally on restart.
- **Initial `ob login` requires interactive access.** Coolify's UI doesn't comfortably support this; you SSH to the host. After bootstrap, this isn't a recurring concern.
- **Image bloat over time.** Repeated rebuilds without pruning accumulate intermediate layers. `docker system prune` occasionally keeps this in check.
- **One sync account, one container instance.** Same caveat as the systemd version — multi-VPS HA isn't a clean fit. Not a personal-blog concern.

## Open questions

- **Where exactly do the SSH keys live in a Coolify-managed setup?** Bind-mounting a host directory is the obvious approach, but Coolify has its own conventions for persistent storage that may be cleaner. Worth a 15-minute spike during build.
- **Do we want a separate "manual sync" entry point?** Right now the only way to force a reconciliation is `docker compose exec content-reconciler /usr/local/bin/sync-content.sh`. Workable but ugly. Could add a tiny helper script at the project root that wraps that, or a Make target.
- **Watchtower / image autoupdate.** Could add Watchtower to the compose stack to auto-pull updated `obsidian-sync` images. Trade-off: less manual maintenance vs. risk of an upstream change breaking sync at an inconvenient time. Probably not for v1.
- **Same content-repo-structure question as `05`.** One repo with subfolders per site vs. one repo per site. Doesn't change anything in this doc; just affects what `GIT_REPO_URL` points at.

## Hand-off Doc Index

- `01-triage.md` — master overview, stack decisions, site bucketing
- `02-handoff-skeleton.md` — the Astro skeleton template repo, spin-up flow
- `03-handoff-content-sync.md` — the content sync architecture chat (Options A/B/C)
- `04-deferred-topics.md` — running backlog
- `05-handoff-vps-content-sync.md` — VPS content sync via host-level systemd
- `06-handoff-vps-content-sync-docker.md` — this doc; VPS content sync via Docker Compose
