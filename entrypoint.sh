#!/bin/bash
set -e

CONFIG_FILE="/config/config.yaml"
CRONTAB_FILE="/config/crontab"
RCLONE_CONF="/config/rclone.conf"

log() {
    echo "[$(date -Iseconds)] [ENTRYPOINT] $1"
}

# Set up user/group
setup_user() {
    log "Setting up user with PUID=${PUID} PGID=${PGID}"

    # Create group if it doesn't exist
    if ! getent group backup >/dev/null 2>&1; then
        groupadd -g "${PGID}" backup
    fi

    # Create user if it doesn't exist
    if ! id backup >/dev/null 2>&1; then
        useradd -u "${PUID}" -g "${PGID}" -d /config -s /bin/bash backup
    fi

    # Fix ownership
    chown -R backup:backup /config /backups
}

# Generate rclone.conf from config.yaml
generate_rclone_conf() {
    log "Generating rclone configuration..."

    local enabled=$(yq -r '.remote.enabled // true' "$CONFIG_FILE")
    if [ "$enabled" != "true" ]; then
        log "Remote sync disabled, skipping rclone config"
        return
    fi

    local bucket=$(yq -r '.remote.bucket // ""' "$CONFIG_FILE")
    local account_id=$(yq -r '.remote.account_id // ""' "$CONFIG_FILE")
    local app_key=$(yq -r '.remote.application_key // ""' "$CONFIG_FILE")

    if [ -z "$account_id" ] || [ -z "$app_key" ]; then
        log "WARNING: B2 credentials not configured in config.yaml"
        return
    fi

    cat > "$RCLONE_CONF" << EOF
[b2]
type = b2
account = ${account_id}
key = ${app_key}
EOF

    chmod 600 "$RCLONE_CONF"
    log "rclone configuration generated"
}

# Generate crontab from config.yaml
generate_crontab() {
    log "Generating crontab..."

    local schedule=$(yq -r '.schedule // "0 4 * * *"' "$CONFIG_FILE")

    cat > "$CRONTAB_FILE" << EOF
# Backup schedule - generated from config.yaml
${schedule} /backup.sh
EOF

    log "Crontab generated with schedule: ${schedule}"
}

# Reload configuration
reload_config() {
    log "Reloading configuration..."
    generate_rclone_conf
    generate_crontab

    # Signal supercronic to reload crontab
    if pkill -HUP supercronic 2>/dev/null; then
        log "Signaled supercronic to reload"
    fi

    log "Configuration reloaded"
}

# Watch for config changes
watch_config() {
    log "Starting config file watcher..."
    while true; do
        inotifywait -q -e modify,create "$CONFIG_FILE" 2>/dev/null || true
        log "Config file changed, reloading..."
        sleep 1  # Debounce
        reload_config
    done
}

# Generate default config if it doesn't exist
generate_default_config() {
    log "Config file not found, copying default from /config.example.yaml..."
    cp /config.example.yaml "$CONFIG_FILE"
    log "Default config created at $CONFIG_FILE - please edit with your settings"
}

# Main
main() {
    log "Backup container starting..."

    # Generate default config if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        generate_default_config
    fi

    # Initial setup
    setup_user
    generate_rclone_conf
    generate_crontab

    # Start config watcher in background
    watch_config &

    log "Starting cron scheduler..."
    exec supercronic "$CRONTAB_FILE"
}

main "$@"
