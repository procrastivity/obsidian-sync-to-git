# Hand-off: VPS Content Sync Setup

> Operational reference for the VPS-based content sync pattern. Resolves several open questions from `03-handoff-content-sync.md` — specifically, what "Option B with Obsidian Sync" actually looks like end-to-end. Implements a specific variant of Option B (file-watcher-on-server) using Obsidian's official headless sync client, with git as the trigger mechanism rather than direct webhook calls.

## Status

Designed, not yet built. This doc is the reference for the build. Tracks the architecture decided in the chat after `03-handoff-content-sync.md`.

## The pipeline at a glance

```
Obsidian on phone/laptop/iPad
        │
        │  (Obsidian Sync, end-to-end encrypted)
        ▼
Headless `ob sync --continuous` on VPS
        │
        │  (files land in /home/obsidian/vault/)
        ▼
Reconciliation script triggered by inotify (debounced ~5s)
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

End-to-end latency: roughly 5 seconds (debounce) + GitHub/Pages build time. Typically ~30s to ~2 minutes total, dominated by the build rather than the sync. A backstop polling cycle (default 15 minutes) ensures content reaches the site even in the unlikely case the watcher misses events.

## Why this shape (compressed reasoning)

`03-handoff-content-sync.md` left three architectures on the table (A: Obsidian-Git, B: file watcher on server, C: custom loader/API) and provisionally leaned A. This pattern is a hybrid that sidesteps the worst parts of both A and B:

- **Why not raw Option A (Obsidian-Git plugin).** The plugin is the flaky part. Running it on multiple devices means git is being driven from multiple writers (phone + desktop + iPad), which is where merge conflicts happen. Single-device git is fine; multi-device git is the boss fight.
- **Why headless sync instead of xvfb.** Until February 2026, "Obsidian on a server" meant running the Electron app under a virtual display. Obsidian shipped an official headless CLI (`ob`) that does sync without a GUI. Removes the awkwardness from Option B.
- **Why git is still in the loop at all.** Obsidian Sync is a sync mechanism, not a publish mechanism. There's no webhook, no API, no server-side endpoint that GitHub Actions or Cloudflare can hook into. Something has to bridge "files on the VPS" → "Cloudflare Pages knows to rebuild." Git is the cheapest, most legible bridge: a GitHub Action triggered by push is exactly the shape we want, and the content repo doubles as durable version history.
- **Why VPS is canonical, GitHub is downstream mirror.** Because the only writer to the content repo is the VPS reconciliation script, the content repo is a derived artifact, not a peer. This licenses force-pushing as a recovery mechanism — discarding remote history just resets it to match the VPS, which is what we want when they ever drift.
- **Why pull-only sync mode.** The VPS receives content but never authors it. Pull-only ensures any accidental mutation on the VPS (script bug, permissions issue, stray edit) doesn't propagate back to real devices.
- **Why convergent rsync rather than delta-tracking.** A reconciliation pattern ("make the git working tree match the vault, then commit whatever delta that produces") self-heals from weird intermediate states. A delta-tracker that's been wrong for an hour stays wrong; a reconciler converges on every run.
- **Why separate the vault from the git working tree.** The vault has Obsidian internals (`.obsidian/`, `.trash/`, plugin state) that don't belong in the content repo. Rsync is the filtering layer. If the git tree ever gets corrupted, blow it away and re-clone — the vault is untouched.

## Setup walkthrough

The whole VPS-side setup is ~30 minutes once you've done it once, dominated by waiting for the initial vault sync to finish.

### 1. Prep the host

As root or sudo:

```sh
# Node 22+ (install via NodeSource if distro repos are older)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs git rsync inotify-tools

# Dedicated system user
sudo useradd --create-home --shell /bin/bash obsidian
sudo -u obsidian mkdir -p /home/obsidian/vault /home/obsidian/bin
```

Adjust package commands for the actual distro. Coolify is irrelevant here — this lives at host level alongside it, not inside it.

### 2. Install `ob` (headless client)

```sh
sudo -iu obsidian
npm install -g @obsidianmd/headless    # cross-check exact package name in the project README
which ob                                # confirm on PATH
```

Project repo: [obsidianmd/obsidian-headless](https://github.com/obsidianmd/obsidian-headless). Check the README at install time for the current package name — the team has been iterating since launch.

### 3. Authenticate and configure the vault

As the `obsidian` user:

```sh
ob login
# Prompts for email, password, and 2FA code if enabled

ob sync-list-remote
# Shows available vaults
```

Set up the vault:

```sh
cd ~/vault
ob sync-setup --vault "Your Vault Name" --path /home/obsidian/vault
```

Then — **important** — switch to pull-only mode and disable config syncing:

```sh
ob sync-config --mode pull-only
ob sync-config --config ""
```

Pull-only is load-bearing for safety (see "Things to watch for" below). Empty config sync means the server doesn't bother pulling theme/plugin/workspace state it has no use for.

Initial sync to pull everything down:

```sh
ob sync
```

This may take a while depending on vault size. Confirm with `ls ~/vault/sites/` that content folders are present.

### 4. The sync daemon

`/etc/systemd/system/obsidian-sync.service`:

```ini
[Unit]
Description=Obsidian headless sync daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=obsidian
WorkingDirectory=/home/obsidian/vault
ExecStart=/usr/bin/ob sync --continuous
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Adjust `ExecStart` to match the actual `ob` path (`which ob` as the obsidian user). Enable:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now obsidian-sync.service
sudo systemctl status obsidian-sync.service
journalctl -u obsidian-sync.service -f
```

From this point, anything saved in Obsidian on any device arrives in `/home/obsidian/vault/` within seconds.

### 5. Content repo + deploy key

Generate an SSH key dedicated to this one job:

```sh
sudo -iu obsidian
ssh-keygen -t ed25519 -f ~/.ssh/content-repo -C "vps-content-sync" -N ""
cat ~/.ssh/content-repo.pub
```

On GitHub, in the content repo: **Settings → Deploy keys → Add deploy key**, paste the public key, **check "Allow write access"**, save. Deploy keys are repo-scoped, so even VPS compromise limits blast radius to one repo.

Configure SSH on the VPS. `/home/obsidian/.ssh/config`:

```
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/content-repo
  IdentitiesOnly yes
```

Test:

```sh
ssh -T git@github.com
# Hi <repo-name>! You've successfully authenticated...
```

Clone the content repo and set committer identity for the automated commits:

```sh
cd ~
git clone git@github.com:OWNER/content-repo.git content-repo
cd content-repo
git config user.email "content-sync@vps"
git config user.name "VPS Content Sync"
```

(Replace `OWNER/content-repo` with the actual repo path. The content repo structure — one repo vs. one per site — is still an open question, see `03-handoff-content-sync.md`.)

### 6. The reconciliation script

`/home/obsidian/bin/sync-content.sh`:

```sh
#!/usr/bin/env sh
set -eu

VAULT="/home/obsidian/vault"
REPO="/home/obsidian/content-repo"

cd "$REPO"

# 1. Make the git working tree match the vault on disk.
#    Only the parts we actually publish.
rsync -a --delete \
  --exclude='.obsidian' \
  --exclude='.trash' \
  "$VAULT/sites/" "$REPO/sites/"

# 2. If nothing changed, exit clean.
git add -A
git diff --staged --quiet && exit 0

# 3. Commit.
git commit -m "sync $(date -u +%FT%TZ)"

# 4. Fetch so the lease for --force-with-lease is current.
git fetch origin main

# 5. Try fast-forward push first; fall back to force-with-lease.
if ! git push origin main 2>/dev/null; then
  echo "fast-forward failed; attempting force-with-lease" >&2
  git push --force-with-lease origin main
fi
```

Make executable:

```sh
chmod +x /home/obsidian/bin/sync-content.sh
```

Also drop in a reset script for when things go genuinely sideways. `/home/obsidian/bin/content-repo-reset.sh`:

```sh
#!/usr/bin/env sh
set -eu

REPO="/home/obsidian/content-repo"
GH_URL="git@github.com:OWNER/content-repo.git"

# Nuke and re-clone.
rm -rf "$REPO"
git clone "$GH_URL" "$REPO"
cd "$REPO"
git config user.email "content-sync@vps"
git config user.name "VPS Content Sync"

# Trigger a normal sync to bring it in line with the vault.
/home/obsidian/bin/sync-content.sh
```

The reset script exists so future-you at 11pm on a Tuesday isn't trying to remember the recovery steps from scratch.

Finally, the watcher script — the one that systemd actually keeps running. It uses `inotifywait` to react to filesystem changes, debounces bursts, and includes a slow polling backstop so that even if the watcher misses events for any reason, syncs still happen on a fallback cadence.

`/home/obsidian/bin/sync-watcher.sh`:

```bash
#!/usr/bin/env bash
set -eu

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-900}"   # 15 minutes
WATCH_DIR="/home/obsidian/vault/sites"
LOCK_DIR="/tmp/sync-content.lock"

# Serialize syncs: only one runs at a time, others skip.
sync_locked() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] sync already in progress; skipping" >&2
        return 0
    fi
    /home/obsidian/bin/sync-content.sh || echo "[$(date -u +%FT%TZ)] sync failed" >&2
    rmdir "$LOCK_DIR"
}

# Initial sync to converge on whatever state is on disk right now.
echo "[$(date -u +%FT%TZ)] initial sync"
sync_locked

# Slow polling backstop — runs in the background regardless of watcher state.
# If inotify dies, drops events, or never sees changes, this still catches them.
(
    while true; do
        sleep "$BACKSTOP_SECONDS"
        echo "[$(date -u +%FT%TZ)] backstop sync"
        sync_locked
    done
) &

# Debounced inotify watcher — the fast path.
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

```sh
chmod +x /home/obsidian/bin/sync-watcher.sh
```

`bash` instead of `sh` is deliberate: the process substitution (`< <(...)`) keeps the `while read` loop in the parent shell so `pending_pid` survives across iterations. `bash` is in Ubuntu's default install; if your distro is unusual, install it.

The `mkdir`/`rmdir` lock around `sync_locked` serializes concurrent attempts (e.g., a backstop sync firing while a debounced sync is mid-flight). Since `mkdir` is atomic on POSIX, exactly one caller wins; the rest skip.

### 7. The watcher service

A single long-running systemd service runs `sync-watcher.sh`. It replaces what would otherwise be a oneshot service plus a timer — the script handles its own scheduling internally (debounce + backstop).

`/etc/systemd/system/sync-content-watcher.service`:

```ini
[Unit]
Description=Watch Obsidian vault and reconcile content repo on change
After=obsidian-sync.service
Requires=obsidian-sync.service

[Service]
Type=simple
User=obsidian
Environment=DEBOUNCE_SECONDS=5
Environment=BACKSTOP_SECONDS=900
ExecStart=/home/obsidian/bin/sync-watcher.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now sync-content-watcher.service
sudo systemctl status sync-content-watcher.service
journalctl -u sync-content-watcher.service -f
```

The two `Environment=` lines are the tuning knobs:

- **`DEBOUNCE_SECONDS=5`** — how long the filesystem must be quiet before a sync fires. Five seconds is a sweet spot for Obsidian Sync bursts (which can land dozens of files in a couple seconds when a device comes online).
- **`BACKSTOP_SECONDS=900`** (15 minutes) — how often the script forces a sync regardless of file events. Insurance against inotify drops, watch-limit exhaustion, or any other case where the fast path silently stops working. Even if the watcher is totally broken, content is at most this stale.

Adjust as desired; defaults are reasonable for personal-blog publishing cadence.

### 8. End-to-end smoke test

From Obsidian on a real device (laptop or phone), create `sites/SITE-NAME/posts/test-vps-sync.md` with placeholder content. Save.

On the VPS, watch the chain unfold:

```sh
# Obsidian Sync delivers the file:
sudo journalctl -u obsidian-sync.service -f

# Within ~5s of the file landing (DEBOUNCE_SECONDS), the watcher fires a sync:
sudo journalctl -u sync-content-watcher.service -f
# Look for "debounced sync" followed by commit/push activity.
```

Over on GitHub, the content repo has a new commit. The path-filtered Action fires the Deploy Hook for the relevant site. Pages builds. Post is live.

Then delete the test file from Obsidian on the same device. Confirm propagation: sync delivers the deletion → next debounced run rsync `--delete` removes from git working tree → commit removes from GitHub → next build no longer includes it.

When that round-trip works, the system is real. As a separate verification: leave the system idle and confirm a "backstop sync" log entry appears every `BACKSTOP_SECONDS` (default 900s) even when nothing's changed. That's the safety net working.

## GitHub-side configuration

This is the right-hand half of the pipeline. Lives in the content repo, not the VPS, but documented here for completeness because it's part of the setup.

### Per-site workflow file

One file per site, in the content repo at `.github/workflows/build-SITE-NAME.yml`:

```yaml
name: Trigger SITE-NAME build
on:
  push:
    branches: [main]
    paths:
      - 'sites/SITE-NAME/**'
jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - name: Hit Pages deploy hook
        run: curl -X POST -f "${{ secrets.SITE_NAME_PAGES_HOOK }}"
```

Path filter ensures a push that only touches one site's folder fires only that site's hook. Adding a 10th site is a 12-line file copy.

### Deploy Hook URLs

Each Cloudflare Pages project has a Deploy Hook URL (Pages dashboard → project → Settings → Builds & deployments → Deploy hooks → Create deploy hook). Treat the URLs as secrets — they're unauthenticated, so anyone with the URL can trigger a build. Add each to the content repo's GitHub Secrets, one per site, named clearly (e.g., `PROCRASTIVITY_PAGES_HOOK`).

### Site-repo side: fetching content at build time

Each site repo's `package.json`:

```json
{
  "scripts": {
    "fetch-content": "scripts/fetch-content.sh",
    "build": "npm run fetch-content && astro build"
  }
}
```

`scripts/fetch-content.sh` does a sparse, shallow clone of just this site's slice of the content repo:

```sh
#!/usr/bin/env sh
set -e
rm -rf content
git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  "https://${CONTENT_REPO_TOKEN}@github.com/OWNER/content-repo.git" \
  content
cd content
git sparse-checkout set sites/SITE-NAME
```

`CONTENT_REPO_TOKEN` is a fine-grained GitHub PAT scoped read-only to the content repo, set as a Pages environment variable (marked Secret). The Astro Content Layer loader points at `content/sites/SITE-NAME/posts/`.

## Things to watch for

- **Pull-only mode is load-bearing.** If switched to bidirectional, a bug or misbehaving script on the VPS could mangle files and that mangling would propagate to all your devices. Leave it set; check `ob sync-config` if anything ever looks off.
- **Credentials live on the VPS.** `ob login` stores an auth token in `~/.config` for the obsidian user. Treat that home directory like it has the keys to your Obsidian Sync account, because it does. 700 perms on the home dir and no random SSH access for that user is sufficient.
- **Deploy keys are repo-scoped.** Good security property; means a VPS compromise can only mess with one repo of markdown. Don't reuse the same key for any other repo.
- **`--force-with-lease`, not `--force`.** The lease check (kept current by the `git fetch` immediately prior) means: succeed silently in the normal case, succeed in the divergence-with-no-concurrent-changes case, fail loudly only if something genuinely weird happened. Plain `--force` is the wrong default — keep that for the manual reset script if at all.
- **The reconciliation script is convergent.** A failed push leaves the local commit behind; the next run (whether debounced or backstop) re-runs the reconciliation, finds nothing new on disk, but the unpushed commit gets pushed. Self-heals across most transient failures.
- **inotify on local filesystems works fine; it isn't universal.** The vault directory is on the VPS's local disk (likely ext4 or xfs) which propagates events cleanly. If you ever bind-mount the vault from an NFS share or use a FUSE filesystem, inotify may see nothing — first symptom is "watching $WATCH_DIR" log lines on startup but no "debounced sync" entries after edits, only "backstop sync" entries. The backstop still keeps you correct on the slow path.
- **`fs.inotify.max_user_watches` is a host-level kernel limit.** Default 8192 on most distros. A very large vault with thousands of subdirectories could exhaust it. Symptom in the journal: `Failed to watch ...; upper limit on inotify watches reached`. Fix: `sudo sysctl -w fs.inotify.max_user_watches=524288` (and persist in `/etc/sysctl.conf`). Unlikely to hit at personal scale; worth knowing exists.
- **The lock around `sync_locked` uses `mkdir`.** Atomic on POSIX filesystems. If a backstop sync fires while a debounced sync is in flight, the second skips cleanly rather than overlapping. On a non-graceful shutdown of `sync-watcher.sh`, the lock dir might be left behind — but `/tmp` is a tmpfs on most distros, so it clears on reboot. If you're on a distro where `/tmp` persists, occasionally check for a stale `/tmp/sync-content.lock` directory.
- **Coolify and this don't interact.** No port conflicts, no filesystem conflicts, no shared services. If Coolify ever moves to a new VPS, this setup is migrated separately and is roughly a one-afternoon job.
- **Updating `ob`.** When new versions ship, it's `npm install -g @obsidianmd/headless@latest` as the obsidian user, then `sudo systemctl restart obsidian-sync.service`. Check the project README occasionally — the team has been moving fast since launch.
- **Pages Deploy Hooks don't expire.** Once created, they live forever unless deleted. If one leaks (committed to a public repo, pasted in chat, etc.), regenerate it in the Pages dashboard.
- **Build logs live in the Pages dashboard, not the VPS.** When deploys fail (bad frontmatter, malformed YAML, transient build error), the log is over on Cloudflare's side. The VPS pipeline just delivers commits; it doesn't know about build outcomes.

## Monitoring (minimal but worth doing)

Two services to care about: `obsidian-sync.service` (sync daemon) and `sync-content-watcher.service` (the file watcher). For each, set up something that pings you on failure. Cheapest version: add `OnFailure=` directives to the systemd units pointing at a small notification helper (Pushover, Healthchecks.io, an SMTP curl, etc.). Goal is "I'll know within 24 hours if publishing has silently broken," not real-time paging.

A useful health signal: the periodic "backstop sync" log entry should appear in `journalctl -u sync-content-watcher.service` every `BACKSTOP_SECONDS`. If you stop seeing those, the watcher is wedged even if the service appears to be running. A cron job that greps the last hour of journal for that line and alerts on absence catches this.

A second layer worth adding eventually: Pages-side notification on build failure. Cloudflare supports email alerts on deploy failure in the dashboard — turn it on, point at the same address.

## What this doesn't solve

- **VPS down = publishing down.** If the VPS goes offline, content on Obsidian devices still syncs to each other (Obsidian Sync continues working — it's hosted by Obsidian, not us), but new posts don't reach the site. Recovery: get the VPS back up; the watcher's initial sync runs immediately on service start and catches up.
- **Monitoring is DIY.** No off-the-shelf "is my content sync pipeline working" dashboard. The journal is the source of truth.
- **One sync account, one VPS.** If a future need arose to have multiple VPSes both syncing (HA setup), this design doesn't handle it cleanly — they'd both try to write to git and the force-with-lease semantics would get messy. Out of scope for personal-blog use.
- **No staging environment.** A push to the content repo goes straight to production. The `drafts/` folder convention (per the workflow design) is the substitute. If a real staging environment ever becomes wanted, it's a second Pages project pointing at the same content repo with a different sparse-checkout filter.

## Open questions

- **Content repo structure: one repo for all sites, or one per site?** The path-filtered Action approach assumes one repo with subfolders per site. One-repo-per-site is cleaner from a permissions and history standpoint but means N deploy keys, N rsync targets, N reconciliation runs on the VPS. Probably one shared repo is fine to start; revisit if it ever feels cramped.
- **Bootstrap order on first build.** First time you set this up, what's the order? Suggested: (1) create the content repo on GitHub as empty, (2) set up the VPS through step 7, (3) populate the vault's `sites/SITE-NAME/posts/` folder with at least one real post and let the reconciliation push it, (4) only then create the site repo and wire up its content fetch and the Pages project. This ensures the site repo's first build has actual content to load.
- **Where does the obsidian user's `.config/` live across VPS rebuilds?** If the VPS ever needs to be rebuilt (kernel upgrade gone wrong, migration to a new host), reauthenticating `ob login` is fine but worth knowing the auth state isn't in the content repo or anywhere else backed up. Worth a periodic `tar -czf` of `/home/obsidian/.config/obsidian/` to offsite storage just in case.

## Hand-off Doc Index

- `01-triage.md` — master overview, stack decisions, site bucketing
- `02-handoff-skeleton.md` — the Astro skeleton template repo, spin-up flow
- `03-handoff-content-sync.md` — the content sync architecture chat (Options A/B/C)
- `04-deferred-topics.md` — running backlog
- `05-handoff-vps-content-sync.md` — this doc; host-level systemd, single shared content repo
- `06-handoff-vps-content-sync-docker.md` — Docker Compose, single shared content repo
- `07-handoff-vps-content-sync-multi-repo.md` — Docker Compose, per-site content repos
- `08-handoff-vps-content-sync-published-images.md` — `07` with images published to GHCR
- `09-handoff-blog-template.md` — the blog-specific Astro template (content collections, post/index/RSS)
