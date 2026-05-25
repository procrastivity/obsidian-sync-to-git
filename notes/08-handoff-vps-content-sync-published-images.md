# Hand-off: VPS Content Sync Setup (Published Images Variant)

> Sibling of `07-handoff-vps-content-sync-multi-repo.md`. Same Pattern B architecture (per-site content repos, one reconciler service per repo, PAT auth) but with the Docker images **published to GitHub Container Registry** and the deployment compose file referencing them by tag instead of building locally.

## Status

Partially implemented in `obsidian-sync-to-git`. Inherits architectural decisions from `05`/`06`/`07`; this doc is the published-images packaging of `07`.

## When to pick this over `07`

`07` keeps everything in one project directory: Dockerfiles, scripts, and the compose file all live together; `docker compose build` builds the images locally on the VPS. `08` splits things across two repos: an images repo with CI that publishes to GHCR, and a deployment repo that pulls those images.

Pick `08` when any of these apply:

- **Site count is growing and reconfigurations are frequent.** Adding a site in `07` requires rebuilding (or at minimum, sitting through a no-op build) on every deploy. `08` makes adding a site a pure compose-file change with no image rebuild.
- **You want reproducible deploys.** Pinning `:v1.0.3` in compose means the running image is exactly the one CI built and tagged. Local builds depend on whatever the source tree happened to be at build time.
- **You're publishing the project for others to use.** Public GHCR images mean adopters can `docker compose up -d` without a build step, without your Dockerfile choices, and without your source tree on their disk.
- **You expect to run multiple deployments.** A staging VPS and a production VPS, or your VPS and a friend's VPS, both pulling the same image rather than each rebuilding from source and possibly diverging.

Pick `07` when:

- You're still iterating on the script/Dockerfile logic and don't want CI in the loop yet.
- This is a one-VPS, one-deployment, won't-be-shared setup.
- Two repos feels like more ceremony than the savings are worth (fair for a single small site).

`07` → `08` migration is straightforward (covered at the end of this doc); starting with `07` and graduating to `08` later is a perfectly reasonable trajectory.

## The two-repo split

Three things on your side now:

1. **`content-sync-images`** — the images repo. Dockerfiles, scripts, GitHub Actions workflow. Changes rarely (a handful of times a year, mostly when `ob` updates).
2. **`content-sync-deployment`** — the deployment repo. Just `docker-compose.yml`, `.env.example`, README. References published images by tag. Changes whenever you add a site or tweak a config.
3. **The per-site content repos** — unchanged from `07`. One repo per site.

Plus, the images repo publishes to GHCR (`ghcr.io/USERNAME/obsidian-sync` and `ghcr.io/USERNAME/reconciler`), which is what the deployment repo pulls from.

The deployment repo is what Coolify points at. The images repo doesn't need Coolify to know about it at all — GitHub Actions handles the build/publish lifecycle entirely.

## The images repo

### Layout

```
content-sync-images/
├── .github/
│   └── workflows/
│       └── release.yml
├── images/
│   ├── obsidian-sync/
│   │   └── Dockerfile
│   └── reconciler/
│       ├── Dockerfile
│       ├── entrypoint.sh
│       └── sync-content.sh
├── docs/
│   ├── releasing.md
│   └── runtime-contract.md
├── examples/
│   ├── sync-source/
│   │   ├── compose.yaml
│   │   ├── .env.example
│   │   ├── .gitignore
│   │   └── README.md
│   └── example-content/
│       ├── .github/
│       │   └── workflows/
│       │       └── trigger-pages-build.yml
│       ├── posts/
│       │   └── .gitkeep
│       └── README.md
├── README.md
└── LICENSE                 # if publishing publicly
```

The implemented images live under `images/`, not as top-level `obsidian-sync/` and `reconciler/` directories. The current Dockerfiles also differ from the original `07` snippets: `obsidian-sync` uses `node:24-slim` and the base image's `node` user; `reconciler` uses `alpine:3.23` and a baked `obsidian` user at UID/GID 1000.

The new piece is the release workflow.

### The release workflow

`.github/workflows/release.yml`:

```yaml
name: Build and publish images

on:
  push:
    branches:
      - main
    tags:
      - 'obsidian-sync-v*'
      - 'reconciler-v*'

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        image:
          - obsidian-sync
          - reconciler
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Resolve image metadata
        id: meta
        shell: bash
        run: |
          set -euo pipefail

          IMAGE="${{ matrix.image }}"
          SHOULD_BUILD=false
          TAGS=""

          if [[ "${GITHUB_REF_TYPE}" == "tag" ]]; then
            TAG="${GITHUB_REF_NAME}"
            TAG_IMAGE="${TAG%-v*}"
            VERSION="v${TAG##*-v}"

            if [[ "$TAG_IMAGE" == "$IMAGE" ]]; then
              SHOULD_BUILD=true
              TAGS=$(cat <<EOF
          ghcr.io/${{ github.repository_owner }}/${IMAGE}:${VERSION}
          ghcr.io/${{ github.repository_owner }}/${IMAGE}:latest
          EOF
          )
            fi
          else
            BEFORE="${{ github.event.before }}"
            AFTER="${{ github.sha }}"

            if [[ "$BEFORE" =~ ^0+$ ]] || ! git cat-file -e "${BEFORE}^{commit}" 2>/dev/null; then
              CHANGED_FILES="$(git ls-tree -r --name-only "$AFTER")"
            else
              CHANGED_FILES="$(git diff --name-only "$BEFORE" "$AFTER")"
            fi

            if echo "$CHANGED_FILES" | grep -Eq "^(images/${IMAGE}/|\\.github/workflows/release\\.yml$)"; then
              SHOULD_BUILD=true
              TAGS="ghcr.io/${{ github.repository_owner }}/${IMAGE}:latest"
            fi
          fi

          {
            echo "should_build=${SHOULD_BUILD}"
            echo "tags<<EOF"
            echo "${TAGS}"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Log in to GHCR
        if: steps.meta.outputs.should_build == 'true'
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Buildx
        if: steps.meta.outputs.should_build == 'true'
        uses: docker/setup-buildx-action@v4

      - name: Build and push
        if: steps.meta.outputs.should_build == 'true'
        uses: docker/build-push-action@v7
        with:
          context: ./images/${{ matrix.image }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          platforms: linux/amd64,linux/arm64
```

What this gives you:

- **Per-image independent versions.** `obsidian-sync-v1.2.0` and `reconciler-v1.0.3` evolve separately. They share a repo but not a release cadence.
- **`latest` tag floats forward.** Every release also updates `:latest`, and pushes to `main` publish `:latest` for each image whose `images/<name>/` subpath changed. Changes to `.github/workflows/release.yml` publish `:latest` for both images because the workflow can affect either build.
- **Multi-arch by default.** `linux/amd64,linux/arm64` covers most VPS hardware including ARM-based Hetzner / Oracle Cloud Ampere instances. Drop `arm64` if you know your hosts are always amd64 — the build is significantly faster without QEMU emulation.
- **`GITHUB_TOKEN` is enough.** No PAT needed for the publish side. The workflow's `permissions.packages: write` is what unlocks the GHCR push.

### Tagging strategy

Releases work by pushing tags:

```sh
# Bump the reconciler script, commit, then:
git tag reconciler-v1.0.4
git push origin reconciler-v1.0.4
# Workflow builds and publishes ghcr.io/USERNAME/reconciler:v1.0.4 + :latest

# Bump the obsidian-sync image (e.g., new ob version), commit, then:
git tag obsidian-sync-v1.3.0
git push origin obsidian-sync-v1.3.0
# Workflow builds and publishes ghcr.io/USERNAME/obsidian-sync:v1.3.0 + :latest
```

Treat tags as the public API of the images repo. Once `reconciler-v1.0.0` is out, don't ever rewrite that tag — bump to `v1.0.1` (or `v2.0.0` for breaking changes) instead. Standard semver.

### Public vs private images

First push creates the package as **private** on GHCR. For a project you intend to share, make it public:

GitHub → Profile → Packages → the package → **Package settings** → Danger Zone → **Change visibility** → Public.

Repeat for both images. Once public, anyone can `docker pull ghcr.io/USERNAME/reconciler:v1.0.3` without auth.

If you keep them private (sensible during early iteration, or if there's anything sensitive in the image), the VPS needs auth to pull (see "Auth for pulling" below).

## The deployment repo

### Layout

```
content-sync-deployment/
├── docker-compose.yml
├── .env.example
├── .env                    # gitignored
├── .gitignore
└── README.md
```

That's it. No Dockerfiles, no scripts, no image build context. The compose file does all the work, and it's referencing images that already exist.

### The compose file

```yaml
services:
  obsidian-sync:
    image: ghcr.io/USERNAME/obsidian-sync:${OBSIDIAN_SYNC_VERSION:-latest}
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - vault:/home/obsidian/vault
      - ob-config:/home/obsidian/.config/obsidian-headless

  reconciler-procrastivity:
    image: ghcr.io/USERNAME/reconciler:${RECONCILER_VERSION:-latest}
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
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
    image: ghcr.io/USERNAME/reconciler:${RECONCILER_VERSION:-latest}
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
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
```

Two structural differences from `07`'s compose file:

- **`image:` instead of `build:`.** Pulls from GHCR instead of building locally.
- **`user:` directive at the service level.** Replaces the earlier PUID/PGID build-arg idea, because pre-built images don't have build args available at deploy time. The implemented images bake in usable defaults (`obsidian-sync` runs as the base `node` user; `reconciler` has an `obsidian` user at 1000:1000), and the runtime `user:` directive is how deployments override UID/GID when volume permissions require it.

### `.env.example`

```
# Host UID/GID
PUID=1000
PGID=1000

# Image versions. Pin to specific versions for reproducibility,
# or use `latest` for ergonomics.
OBSIDIAN_SYNC_VERSION=v1.3.0
RECONCILER_VERSION=v1.1.2

# Fine-grained PAT with content:write scope on each per-site content repo.
GH_TOKEN=github_pat_...

# Per-site content repo URLs
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

Pinning explicit versions in production deployments is the safer default. `:latest` is convenient for personal use but means an image update auto-rolls out on next pull — fine until it isn't.

### Multi-owner content repos

The single `GH_TOKEN` in the example above assumes all content repos share one GitHub resource owner. **Fine-grained PATs are scoped to a single resource owner**, so any setup with content repos under more than one owner (e.g., a personal account *and* an org) needs one PAT per owner.

The pattern is identical to the one documented in `07`'s "Multi-owner content repos" section: define multiple token vars in `.env` (e.g. `SIMENSEN_GH_TOKEN`, `PROCRASTIVITY_GH_TOKEN`), then per-reconciler in the compose file route the appropriate one to `GH_TOKEN`:

```yaml
  reconciler-beausimensen-com:
    image: ghcr.io/USERNAME/reconciler:${RECONCILER_VERSION:-latest}
    # ...
    environment:
      - GIT_REPO_URL=${BEAUSIMENSEN_COM_REPO_URL}
      - VAULT_SUBPATH=sites/beausimensen-com
      - GH_TOKEN=${SIMENSEN_GH_TOKEN}
      # ... other env vars

  reconciler-procrastivity-fm:
    image: ghcr.io/USERNAME/reconciler:${RECONCILER_VERSION:-latest}
    # ...
    environment:
      - GIT_REPO_URL=${PROCRASTIVITY_FM_REPO_URL}
      - VAULT_SUBPATH=sites/procrastivity-fm
      - GH_TOKEN=${PROCRASTIVITY_GH_TOKEN}
      # ... other env vars
```

The reconciler image only knows about `GH_TOKEN`; the variable names on the right-hand side of the `=` are your choice. See `07-handoff-vps-content-sync-multi-repo.md`, "Multi-owner content repos" subsection, for the full rationale and alternatives (classic PAT, owner consolidation).

This isn't a versioned image concern — both v1.1.0 and v1.1.1 of the reconciler handle this transparently because routing happens at the compose layer, not in the image.

## Auth for pulling

### Public images: no auth

If the GHCR packages are public, `docker compose pull` and `docker compose up -d` just work. Nothing else to configure on the VPS.

### Private images: docker login

If kept private, the VPS authenticates once with a PAT scoped to `read:packages`:

```sh
echo "$GHCR_PULL_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
```

`GHCR_PULL_TOKEN` is a classic PAT (or fine-grained with `read:packages`) generated in GitHub Settings → Developer settings → Personal access tokens. Stored on the VPS only; Docker caches the credential at `~/.docker/config.json`.

In Coolify, the cleaner path is the built-in registry credential manager: **Settings → Registries → Add registry**, point at `ghcr.io`, provide the PAT. Coolify handles auth transparently when pulling images for any Compose deployment.

## Setup walkthrough

### First-time bootstrap (both repos from scratch)

This is the path you walk once, when first switching to `08`.

**1. Create `content-sync-images` repo.**

Bring over the Dockerfiles and scripts under `images/obsidian-sync/` and `images/reconciler/`. Add the release workflow at `.github/workflows/release.yml`. Push to GitHub.

**2. Publish initial versions.**

```sh
cd content-sync-images
git tag obsidian-sync-v1.0.0
git tag reconciler-v1.0.0
git push origin --tags
```

Watch the Actions tab; both workflows should succeed and produce images at `ghcr.io/USERNAME/obsidian-sync:v1.0.0` and `ghcr.io/USERNAME/reconciler:v1.0.0`.

**3. Make packages public** (if you want public pulls). Per the "Public vs private" section above.

**4. Create `content-sync-deployment` repo.**

Put the compose file, `.env.example`, `.gitignore`, README. Push to GitHub.

**5. On the VPS:** clone the deployment repo, fill in `.env`, do the one-time `ob login` dance.

```sh
git clone git@github.com:USERNAME/content-sync-deployment.git
cd content-sync-deployment
cp .env.example .env
$EDITOR .env   # fill in GH_TOKEN, repo URLs, image versions, etc.

# If using private images:
echo "$GHCR_PULL_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin

# Pull images
docker compose pull

# Interactive ob bootstrap (same as 06/07)
docker compose run --rm obsidian-sync ob login
docker compose run --rm obsidian-sync ob sync-list-remote
docker compose run --rm obsidian-sync ob sync-setup \
    --vault "Your Vault Name" \
    --path /home/obsidian/vault
docker compose run --rm obsidian-sync ob sync-config \
    --path /home/obsidian/vault --configs ""
docker compose run --rm obsidian-sync ob sync

# Bring up the stack
docker compose up -d
```

**6. Smoke test** per `07`'s walkthrough. Move a file in Obsidian, watch it propagate through.

### Day-to-day: adding a site

Pure deployment-repo change. No image rebuilds.

1. Edit `docker-compose.yml`, add a new `reconciler-newsite` service block + named volume.
2. Edit `.env`, add `NEWSITE_REPO_URL=...`.
3. Update the PAT scope to include the new content repo.
4. `docker compose up -d` — pulls the existing reconciler image (already on disk), starts the new container.

End to end: ~60 seconds, no CI involved.

### Day-to-day: updating an image

Rare, but the path is:

1. In `content-sync-images`, edit the relevant file under `images/<image-name>/`.
2. Commit, tag (e.g., `reconciler-v1.0.4`), push.
3. Wait for the workflow to publish.
4. On the VPS:
   ```sh
   $EDITOR .env   # bump RECONCILER_VERSION=v1.0.4
   docker compose pull
   docker compose up -d
   ```
   The `up -d` recreates containers whose image reference changed; obsidian-sync stays running untouched.

If you're on `:latest` tags instead of pinned versions, skip step 4's edit — `docker compose pull && docker compose up -d` is the whole update flow.

## Coolify integration

Same shape as `06`/`07`, with one welcome simplification: no `build` context means Coolify doesn't need access to Dockerfile source. The deployment repo is purely declarative.

1. Push `content-sync-deployment` to a git repo Coolify can read.
2. **Add Resource → Docker Compose**, point at the repo.
3. Set env vars via Coolify's UI (`GH_TOKEN`, `OBSIDIAN_SYNC_VERSION`, `RECONCILER_VERSION`, per-site `*_REPO_URL`, etc.).
4. If using private images: configure the GHCR registry credentials in Coolify's registries section.
5. Deploy.

The interactive `ob login` constraint is unchanged from `07` — SSH-and-`docker exec`, one-time.

A small ergonomic win in Coolify with `08`: redeploys are fast because there's no build phase. Coolify pulls (cached layers, usually instant), recreates containers, done.

## GitHub-side configuration

Unchanged from `07`. See `07-handoff-vps-content-sync-multi-repo.md`, "GitHub-side configuration" section, for:

- Per-content-repo Action or webhook to fire the Pages Deploy Hook
- Pages Deploy Hook setup
- Site-repo `fetch-content.sh` with the read-only PAT

None of that touches images or registry.

## Things to watch for

- **Reconciler v1.1.0+ ships the file-watcher entrypoint.** Earlier reconciler versions used a simple polling loop (`SLEEP_INTERVAL` env var, fixed cadence). Starting at v1.1.0, the entrypoint is `inotifywait`-driven with a debounced fast path and a backstop poll. The env-var contract changed: `SLEEP_INTERVAL` is gone; `DEBOUNCE_SECONDS` and `BACKSTOP_SECONDS` replace it. Pinning to a pre-v1.1.0 image with the new env vars set is harmless (they get ignored); pinning to v1.1.0+ with the old `SLEEP_INTERVAL` set is also harmless (it gets ignored). The `.env.example` above assumes v1.1.2+.
- **Reconciler v1.1.1 fixes a drafts-handling bug.** v1.1.0 (and earlier) synced any `drafts/` directory in the vault to the content repo, which caused unnecessary builds when editing drafts and put work-in-progress on GitHub. v1.1.1 adds `--exclude='drafts'` to the rsync and to the inotify watch pattern, so drafts stay local to the vault and never enter the publish pipeline. If you're on v1.1.0, upgrade to v1.1.1+ — particularly if your content repos are public.
- **Reconciler v1.1.2 fixes a repo-root-clobbering bug.** v1.1.1 (and earlier) had `rsync --delete` without excludes for `.github`, `README*`, or `LICENSE*`. Since the rsync target is the repo root and the source is the vault subpath, anything at the repo root not present in the vault was deleted on every reconciliation — including the GitHub Action workflow that fires the Pages Deploy Hook. First sync after deploy would silently delete the workflow file, breaking subsequent build triggers. v1.1.2 adds `--exclude='.github'`, `--exclude='README*'`, `--exclude='LICENSE*'` so repo-root infrastructure is protected. Upgrade to v1.1.2 unconditionally — earlier versions are broken in any setup where the content repo contains a GitHub Action workflow.
- **Image tag drift in `.env`.** Pinned versions in `.env` mean nothing rolls out until you bump them — but it also means you can forget to bump them, sitting on stale images for months. Worth a periodic check (every few months) of whether anything's been released in `content-sync-images` that the deployment hasn't picked up yet.
- **`:latest` is convenient and dangerous.** A `:latest` tag means `docker compose pull && docker compose up -d` auto-applies whatever was most recently published. Fine for personal use; less fine if you publish the project and adopters use `:latest` in production. Recommend pinning in the public `.env.example`.
- **GHCR retention policies.** GHCR doesn't auto-delete old image versions by default, but if you set up a retention policy, make sure to exclude tagged releases. Auto-deleting `v1.0.0` because it's "old" would break anyone pinning to it.
- **Public packages can't trivially go private again.** Visibility changes are technically reversible but GHCR may have cached pulls of the public version. Treat the public/private decision as one-way.
- **Multi-arch builds add CI time.** ~3x longer than amd64-only because of QEMU emulation. For a 1-image-per-release pace it's fine; if you find yourself rebuilding frequently, consider dropping arm64 unless you actually need it.
- **`user:` runtime directive requires the image to support it.** The Dockerfiles in `06`/`07` create an `obsidian` user but the entrypoint expects to read/write the home directory. If the runtime UID/GID differs from what the image was built with, file permissions inside the container can get weird. Sticking to UID 1000 host-side and matching that in the image avoids this entirely.
- **Pull-only sync mode isn't actually configured.** Same correction as in `05`/`06`/`07`: bare `obsidian-headless` has no pull-only flag. The `:ro` mount on each reconciler service is the actual mechanism preventing VPS-side mutations from propagating back to your devices. If you want explicit enforcement, swap the `obsidian-sync` service for [Belphemur's image](https://github.com/Belphemur/obsidian-headless-sync-docker), which exposes `SYNC_MODE=pull-only` via env var.
- **inotify on Docker volumes.** Named volumes on local filesystems (ext4, xfs, overlayfs) propagate events fine. NFS-backed and some FUSE volume drivers silently see no events. First symptom: "watching $WATCH_DIR" log lines on startup but no "debounced sync" lines after edits — only "backstop sync" lines. Backstop keeps the system correct on the slow path.
- **`fs.inotify.max_user_watches` is host-level kernel state.** Default 8192 on most distros; a very large vault tree could exhaust it. Symptom: `inotifywait` exits with `Failed to watch ...; upper limit on inotify watches reached`. Fix: `sysctl -w fs.inotify.max_user_watches=524288` on the host, persist in `/etc/sysctl.conf`. Unlikely to hit at personal-blog scale; documented for completeness.

## Publishing as a reusable project

If you intend to share this, a few things worth doing before announcing:

**Naming.** Something distinct and searchable. `obsidian-vault-publisher`, `obsidian-content-sync`, `obsidian-to-git`, etc. The image names follow from this — `ghcr.io/USERNAME/obsidian-vault-publisher-sync` and `...-reconciler` (or just `obsidian-sync` and `reconciler` if you want shorter names per package).

**README contract.** The deployment repo's README is what adopters read. Cover:

- What problem this solves (one-paragraph elevator).
- Prerequisites (Obsidian Sync subscription, VPS, GitHub account, Cloudflare Pages projects).
- Architecture diagram (the pipeline-at-a-glance from this doc works).
- Setup instructions (essentially the "First-time bootstrap" section, generalized).
- The env var reference (every variable, what it does, sensible defaults).
- Troubleshooting (failure modes from `07`'s "Things to watch for," plus image-specific ones).
- A link to the images repo for adopters who want to inspect or fork the Dockerfiles.

**Semver discipline.** Once you publish `reconciler-v1.0.0`, treat the env-var contract as stable. Changes that break adopters' `.env` files (renaming `GH_TOKEN`, changing how `VAULT_SUBPATH` is interpreted, etc.) are major-version bumps. Bug fixes are patch. New features that don't break existing configs are minor.

**Example configurations.** A `docker-compose.example.yml` showing the minimum (one site, single reconciler) and another showing a richer setup (multi-site, custom env values, monitoring hooks). Adopters copy these as starting points.

**License.** MIT or Apache 2.0 are the easy picks for permissive infra projects.

**A "what this isn't" section in the README.** Saves adopter time. E.g., "This isn't a full CMS, it doesn't handle media optimization, it doesn't provide an admin UI, it assumes you're comfortable with Cloudflare Pages and basic git workflows."

## Migrating from `07` to `08`

If you've already built `07` and want to switch:

1. Create `content-sync-images`, copy in the `images/obsidian-sync/` and `images/reconciler/` directories from your `07` project, add the release workflow.
2. Tag and publish initial versions (`obsidian-sync-v1.0.0`, `reconciler-v1.0.0`).
3. Create `content-sync-deployment`, copy `docker-compose.yml` from `07`.
4. Edit the compose file: replace each service's `build:` block with `image: ghcr.io/USERNAME/...:${VERSION}`. If the old compose file used PUID/PGID build args, move that concern to a top-level runtime `user: "${PUID}:${PGID}"` directive.
5. Add `OBSIDIAN_SYNC_VERSION` and `RECONCILER_VERSION` to `.env`.
6. On the VPS: `cd` into the new deployment repo, copy over the `.env` from the old one (plus the new version vars), `docker compose pull`, `docker compose up -d`.

The named volumes from `07` (`vault`, `ob-config`, `*-repo`) persist by default — they're named, not anonymous, and `docker compose down` doesn't remove them. The transition is essentially zero-downtime as long as the new compose file uses the same volume names.

The old `07` project directory becomes archival; you can delete it once you've confirmed `08` is healthy. Definitely keep the `ob` credential state until you've verified the new stack syncs cleanly.

## What this doesn't solve

- **VPS down = publishing down.** Unchanged.
- **Interactive `ob login` requires `docker exec`.** Unchanged.
- **PAT expiration is still a chore.** Unchanged from `07`.
- **Image vulnerabilities.** Pinning a specific image version means you stay vulnerable to whatever's in that version until you bump. GitHub has Dependabot for container images that can auto-PR version bumps in the deployment repo if you turn it on — modest workflow improvement.

## Open questions

- **Single combined image, or two separate images?** Current design has two (obsidian-sync, reconciler). Combining them into one image with two entrypoints is possible but the reconciler genuinely doesn't need Node and obsidian-sync genuinely doesn't need git/rsync/SSH. Two stays cleaner.
- **`latest` in `.env.example` vs pinned versions.** Lean toward pinned for the example file, with a comment explaining the trade-off. Adopters copy the example; what they copy is what they live with.
- **Whether to publish at all.** Worth doing only if you genuinely want to. Public projects come with implicit expectations (responsiveness to issues, maintenance commitment) that might not match how much energy you want to put into this. A perfectly legitimate alternative is keeping everything private and the project just being your personal infrastructure.
- **Should the images repo also publish to Docker Hub?** GHCR is sufficient for most use cases and integrates naturally with the GitHub-centric stack. Docker Hub adds visibility (better search/discoverability for adopters) at the cost of another auth flow in CI. Probably skip unless adopter requests pile up.

## Hand-off Doc Index

- `01-triage.md` — master overview, stack decisions, site bucketing
- `02-handoff-skeleton.md` — the Astro skeleton template repo, spin-up flow
- `03-handoff-content-sync.md` — the content sync architecture chat (Options A/B/C)
- `04-deferred-topics.md` — running backlog
- `05-handoff-vps-content-sync.md` — VPS content sync via host-level systemd (Pattern A, single repo)
- `06-handoff-vps-content-sync-docker.md` — VPS content sync via Docker Compose (Pattern A, single repo)
- `07-handoff-vps-content-sync-multi-repo.md` — Docker Compose, Pattern B (per-site repos), local image builds
- `08-handoff-vps-content-sync-published-images.md` — this doc; Pattern B with images published to GHCR
