FROM node:24-slim

LABEL org.opencontainers.image.source="https://github.com/procrastivity/obsidian-sync-to-git" \
      org.opencontainers.image.description="Obsidian Headless sync image for obsidian-sync-to-git" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g obsidian-headless

RUN mkdir -p /home/obsidian/vault /home/obsidian/.config/obsidian \
 && chown -R node:node /home/obsidian \
 && chmod -R a+rwX /home/obsidian

ENV HOME=/home/obsidian

USER node
WORKDIR /home/obsidian/vault

CMD ["ob", "sync", "--continuous"]
