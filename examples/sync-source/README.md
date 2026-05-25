# Sync Source Example

This example is the deployment-side stack: one `obsidian-sync` service that keeps the vault volume current, plus one reconciler service that mirrors a vault subpath into a per-site content repo.

Copy `.env.example` to `.env`, fill in the repository URL and token values, then use `compose.yaml` with Docker Compose or Coolify.
