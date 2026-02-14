FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    bash \
    p7zip \
    rclone \
    curl \
    jq \
    yq \
    inotify-tools \
    tzdata \
    shadow

# Install supercronic (better cron for containers)
ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-amd64
ARG SUPERCRONIC_SHA1SUM=cd48d45c4b10f3f0bfdd3a57d054cd05ac96812b
RUN curl -fsSLO "$SUPERCRONIC_URL" \
    && echo "${SUPERCRONIC_SHA1SUM}  supercronic-linux-amd64" | sha1sum -c - \
    && chmod +x supercronic-linux-amd64 \
    && mv supercronic-linux-amd64 /usr/local/bin/supercronic

# Create directories
RUN mkdir -p /config /backups /source

# Copy scripts and default config
COPY entrypoint.sh /entrypoint.sh
COPY backup.sh /backup.sh
COPY config.example.yaml /config.example.yaml
RUN chmod +x /entrypoint.sh /backup.sh

# Default environment
ENV TZ=UTC
ENV PUID=1000
ENV PGID=1000

VOLUME ["/config", "/backups", "/source"]

ENTRYPOINT ["/entrypoint.sh"]
