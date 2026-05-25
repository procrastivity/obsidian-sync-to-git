# obsidian-sync-to-git

Sync content from Obsidian Sync to Git content repositories.

This repo publishes two Docker images to GitHub Container Registry:

- `obsidian-sync`: runs the Obsidian Headless CLI continuously.
- `reconciler`: watches a vault subpath, mirrors it into a Git working tree, commits, and pushes.

## Repository Layout

- `images/obsidian-sync`: Obsidian Headless image.
- `images/reconciler`: vault-path-to-Git reconciler image.
- `examples/sync-source`: deployment/Coolify compose example.
- `examples/example-content`: per-site content repo example.
- `docs/`: runtime and release notes.

## Usage

Start from `examples/sync-source/compose.yaml`, set the required environment variables, then run the one-time Obsidian Headless setup documented in `docs/runtime-contract.md`.

## Releasing

See `docs/releasing.md`.
