FROM alpine:3.20

LABEL org.opencontainers.image.source="https://github.com/procrastivity/obsidian-sync-to-git" \
      org.opencontainers.image.description="Vault subpath to Git reconciler image for obsidian-sync-to-git" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
    bash \
    ca-certificates \
    git \
    inotify-tools \
    rsync

RUN addgroup -g 1000 obsidian \
 && adduser -D -u 1000 -G obsidian -s /bin/bash obsidian \
 && mkdir -p /repo /home/obsidian \
 && chown -R obsidian:obsidian /repo /home/obsidian \
 && chmod -R a+rwX /repo /home/obsidian

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY sync-content.sh /usr/local/bin/sync-content.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/sync-content.sh

ENV HOME=/home/obsidian

USER obsidian
WORKDIR /repo

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
