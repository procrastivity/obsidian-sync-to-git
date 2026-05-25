# Runtime Contract

## `obsidian-sync`

Runs the Obsidian Headless CLI continuously:

```sh
ob sync --continuous
```

Expected persistent volumes:

- `/home/obsidian/vault`
- `/home/obsidian/.config/obsidian-headless`

One-time setup is interactive and should be run against those same volumes:

```sh
docker compose run --rm obsidian-sync ob login
docker compose run --rm obsidian-sync ob sync-list-remote
docker compose run --rm obsidian-sync ob sync-setup --vault "Your Vault Name" --path /home/obsidian/vault
docker compose run --rm obsidian-sync ob sync-config --configs ""
docker compose run --rm obsidian-sync ob sync
```

The bare `obsidian-headless` CLI does not expose a pull-only mode. The
reconciler's read-only `/vault` mount is the implemented guardrail that keeps
the Git publishing side from mutating vault state.

## `reconciler`

Watches a vault subpath, mirrors it into a Git working tree, commits, and pushes.

Expected mounts:

- `/vault` mounted read-only from the Obsidian vault volume
- `/repo` mounted as a persistent Git working tree volume

Required environment variables:

- `GIT_REPO_URL`
- `GH_TOKEN`
- `VAULT_SUBPATH`

Optional environment variables:

- `GIT_BRANCH`, default `main`
- `GIT_EMAIL`, default `content-sync@vps`
- `GIT_NAME`, default `VPS Content Sync`
- `DEBOUNCE_SECONDS`, default `5`
- `BACKSTOP_SECONDS`, default `900`
