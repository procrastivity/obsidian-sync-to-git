# Releasing

Images are published to GitHub Container Registry in two ways:

- Pushes to `main` publish `:latest` for each image whose `images/<name>/` subpath changed.
- Release tags publish a versioned tag and also move that image's `:latest` tag.

Changing `.github/workflows/release.yml` publishes `:latest` for both images on the next `main` push, because workflow changes can affect either build.

## Continuous `latest`

Editing files under `images/obsidian-sync/` and pushing to `main` publishes:

- `ghcr.io/OWNER/obsidian-sync:latest`

Editing files under `images/reconciler/` and pushing to `main` publishes:

- `ghcr.io/OWNER/reconciler:latest`

Docs and example-only changes do not publish images.

## Versioned Releases

```sh
git tag obsidian-sync-v1.0.0
git push origin obsidian-sync-v1.0.0

git tag reconciler-v1.0.0
git push origin reconciler-v1.0.0
```

The workflow builds from `images/<image-name>` and publishes:

- `ghcr.io/OWNER/obsidian-sync:vX.Y.Z`
- `ghcr.io/OWNER/obsidian-sync:latest`
- `ghcr.io/OWNER/reconciler:vX.Y.Z`
- `ghcr.io/OWNER/reconciler:latest`

For the first release:

```sh
git tag obsidian-sync-v1.0.0
git tag reconciler-v1.0.0
git push origin --tags
```

After the first workflow run, check the Actions tab and GHCR package pages.
