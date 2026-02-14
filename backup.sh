#!/bin/bash
set -euo pipefail

CONFIG_FILE="/config/config.yaml"
RCLONE_CONF="/config/rclone.conf"
BACKUP_DIR="/backups"

# Timing
START_TIME=$(date +%s)
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_NAME="backup_${TIMESTAMP}.7z"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Status tracking
BACKUP_SUCCESS=false
SYNC_SUCCESS=false
BACKUP_SIZE=0
FILE_COUNT=0
ERROR_MESSAGE=""

# Logging
LOG_LEVEL=$(yq -r '.logging.level // "info"' "$CONFIG_FILE")
LOG_FILE=$(yq -r '.logging.file // "/config/backup.log"' "$CONFIG_FILE")

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -Iseconds)
    local log_line="[${timestamp}] [${level^^}] ${message}"

    # Log to stdout
    echo "$log_line"

    # Log to file
    echo "$log_line" >> "$LOG_FILE"
}

log_debug() { [[ "$LOG_LEVEL" == "debug" ]] && log "DEBUG" "$1" || true; }
log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }

# Send Discord notification
send_discord_notification() {
    local status="$1"  # success or failure
    local enabled=$(yq -r '.notifications.discord.enabled // false' "$CONFIG_FILE")

    if [ "$enabled" != "true" ]; then
        log_debug "Discord notifications disabled"
        return
    fi

    local webhook_url=$(yq -r '.notifications.discord.webhook_url // ""' "$CONFIG_FILE")
    local on_success=$(yq -r '.notifications.discord.on_success // false' "$CONFIG_FILE")
    local on_failure=$(yq -r '.notifications.discord.on_failure // true' "$CONFIG_FILE")

    if [ -z "$webhook_url" ]; then
        log_warn "Discord webhook URL not configured"
        return
    fi

    # Check if we should send notification
    if [ "$status" = "success" ] && [ "$on_success" != "true" ]; then
        log_debug "Skipping success notification (on_success=false)"
        return
    fi

    if [ "$status" = "failure" ] && [ "$on_failure" != "true" ]; then
        log_debug "Skipping failure notification (on_failure=false)"
        return
    fi

    local duration=$(($(date +%s) - START_TIME))
    local color

    if [ "$status" = "success" ]; then
        color=3066993  # Green
        title="Backup Successful"
    else
        color=15158332  # Red
        title="Backup Failed"
    fi

    local size_human=$(numfmt --to=iec-i --suffix=B "$BACKUP_SIZE" 2>/dev/null || echo "${BACKUP_SIZE} bytes")

    local payload=$(cat << EOF
{
    "embeds": [{
        "title": "${title}",
        "color": ${color},
        "fields": [
            {"name": "Archive", "value": "${BACKUP_NAME}", "inline": true},
            {"name": "Size", "value": "${size_human}", "inline": true},
            {"name": "Duration", "value": "${duration}s", "inline": true},
            {"name": "Backup", "value": "${BACKUP_SUCCESS}", "inline": true},
            {"name": "Sync", "value": "${SYNC_SUCCESS}", "inline": true}
        ],
        "timestamp": "$(date -Iseconds)"
    }]
}
EOF
)

    # Add error message if present
    if [ -n "$ERROR_MESSAGE" ]; then
        payload=$(echo "$payload" | jq --arg err "$ERROR_MESSAGE" '.embeds[0].fields += [{"name": "Error", "value": $err, "inline": false}]')
    fi

    log_debug "Sending Discord notification..."
    if curl -s -H "Content-Type: application/json" -d "$payload" "$webhook_url" > /dev/null; then
        log_info "Discord notification sent"
    else
        log_warn "Failed to send Discord notification"
    fi
}

# Get backup epoch from filename
get_backup_epoch() {
    local file="$1"
    local base=$(basename "$file")
    local datetime_part=$(echo "$base" | cut -d'_' -f2,3)
    datetime_part=${datetime_part%.7z}
    local full_datetime=$(echo "$datetime_part" | sed 's/_/ /')
    local backup_date=$(echo "$full_datetime" | awk '{print $1}')
    local backup_time=$(echo "$full_datetime" | awk '{print $2}' | sed 's/-/:/g')
    date -D "%Y-%m-%d %H:%M:%S" -d "$backup_date $backup_time" +%s
}

# Get week number from backup filename
get_backup_week() {
    local file="$1"
    local base=$(basename "$file")
    local datetime_part=$(echo "$base" | cut -d'_' -f2,3)
    datetime_part=${datetime_part%.7z}
    local backup_date=$(echo "$datetime_part" | cut -d'_' -f1)
    date -d "$backup_date" +%Y-W%V
}

# Create 7z backup
create_backup() {
    log_info "Creating backup: ${BACKUP_NAME}"

    # Read sources and excludes from config
    local sources=()
    local excludes=()

    # Read sources array
    while IFS= read -r source; do
        if [ -n "$source" ] && [ "$source" != "null" ]; then
            sources+=("$source")
        fi
    done < <(yq -r '.sources[]' "$CONFIG_FILE" 2>/dev/null)

    # Read excludes array
    while IFS= read -r exclude; do
        if [ -n "$exclude" ] && [ "$exclude" != "null" ]; then
            excludes+=("-xr!$exclude")
        fi
    done < <(yq -r '.excludes[]' "$CONFIG_FILE" 2>/dev/null)

    if [ ${#sources[@]} -eq 0 ]; then
        log_error "No backup sources configured"
        return 1
    fi

    log_info "Backing up ${#sources[@]} source(s) with ${#excludes[@]} exclusion(s)"
    log_debug "Sources: ${sources[*]}"
    log_debug "Excludes: ${excludes[*]}"

    # Create backup (-bsp1 shows progress percentage)
    # Exit codes: 0=success, 1=warning (non-fatal, e.g. missing files), 2+=fatal error
    local exit_code=0
    7z a -mmt -spf2 -bsp1 "$BACKUP_PATH" "${excludes[@]}" "${sources[@]}" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        BACKUP_SIZE=$(stat -c%s "$BACKUP_PATH" 2>/dev/null || echo 0)
        FILE_COUNT=$(7z l "$BACKUP_PATH" 2>/dev/null | tail -1 | awk '{print $5}' || echo 0)
        log_info "Backup created: ${BACKUP_PATH} ($(numfmt --to=iec-i --suffix=B "$BACKUP_SIZE" 2>/dev/null || echo "${BACKUP_SIZE} bytes"))"
        return 0
    elif [ $exit_code -eq 1 ]; then
        BACKUP_SIZE=$(stat -c%s "$BACKUP_PATH" 2>/dev/null || echo 0)
        FILE_COUNT=$(7z l "$BACKUP_PATH" 2>/dev/null | tail -1 | awk '{print $5}' || echo 0)
        log_warn "Backup created with warnings: ${BACKUP_PATH} ($(numfmt --to=iec-i --suffix=B "$BACKUP_SIZE" 2>/dev/null || echo "${BACKUP_SIZE} bytes"))"
        return 0
    else
        log_error "Failed to create backup (exit code: $exit_code)"
        return 1
    fi
}

# Get month from backup filename
get_backup_month() {
    local file="$1"
    local base=$(basename "$file")
    local datetime_part=$(echo "$base" | cut -d'_' -f2,3)
    datetime_part=${datetime_part%.7z}
    local backup_date=$(echo "$datetime_part" | cut -d'_' -f1)
    date -d "$backup_date" +%Y-%m
}

# Prune old backups
prune_backups() {
    log_info "Pruning old backups..."

    local keep_daily=$(yq -r '.retention.keep_daily // 7' "$CONFIG_FILE")
    local keep_weekly=$(yq -r '.retention.keep_weekly // 4' "$CONFIG_FILE")
    local keep_monthly=$(yq -r '.retention.keep_monthly // 6' "$CONFIG_FILE")

    local now_epoch=$(date +%s)
    local daily_cutoff=$((now_epoch - (keep_daily * 86400)))
    local weekly_cutoff=$((now_epoch - (keep_weekly * 7 * 86400)))
    local monthly_cutoff=$((now_epoch - (keep_monthly * 30 * 86400)))

    declare -A latest_weekly
    declare -A latest_monthly
    declare -a keep_files

    # First pass: identify all backups and categorize them
    for file in "$BACKUP_DIR"/backup_*.7z; do
        [ -f "$file" ] || continue

        local file_epoch=$(get_backup_epoch "$file")
        local week=$(get_backup_week "$file")
        local month=$(get_backup_month "$file")

        # Track latest backup per week
        if [ -z "${latest_weekly[$week]:-}" ]; then
            latest_weekly[$week]="$file"
        else
            local stored_epoch=$(get_backup_epoch "${latest_weekly[$week]}")
            if [ "$file_epoch" -gt "$stored_epoch" ]; then
                latest_weekly[$week]="$file"
            fi
        fi

        # Track latest backup per month
        if [ -z "${latest_monthly[$month]:-}" ]; then
            latest_monthly[$month]="$file"
        else
            local stored_epoch=$(get_backup_epoch "${latest_monthly[$month]}")
            if [ "$file_epoch" -gt "$stored_epoch" ]; then
                latest_monthly[$month]="$file"
            fi
        fi
    done

    # Second pass: decide what to keep
    for file in "$BACKUP_DIR"/backup_*.7z; do
        [ -f "$file" ] || continue

        local file_epoch=$(get_backup_epoch "$file")
        local week=$(get_backup_week "$file")
        local month=$(get_backup_month "$file")
        local dominated=false

        # Keep if within daily retention period
        if [ "$file_epoch" -ge "$daily_cutoff" ]; then
            keep_files+=("$file")
            continue
        fi

        # Keep if it's the latest for its week and within weekly retention
        if [ "$file" = "${latest_weekly[$week]}" ] && [ "$file_epoch" -ge "$weekly_cutoff" ]; then
            keep_files+=("$file")
            continue
        fi

        # Keep if it's the latest for its month and within monthly retention
        if [ "$file" = "${latest_monthly[$month]}" ] && [ "$file_epoch" -ge "$monthly_cutoff" ]; then
            keep_files+=("$file")
            continue
        fi
    done

    # Third pass: delete files not in keep list
    local deleted=0
    for file in "$BACKUP_DIR"/backup_*.7z; do
        [ -f "$file" ] || continue

        local should_keep=false
        for keep in "${keep_files[@]}"; do
            if [ "$file" = "$keep" ]; then
                should_keep=true
                break
            fi
        done

        if [ "$should_keep" = false ]; then
            log_info "Deleting old backup: $file"
            rm -f "$file"
            deleted=$((deleted + 1))
        fi
    done

    log_info "Pruning complete: deleted $deleted backup(s), keeping ${#keep_files[@]} backup(s)"
}

# Sync to B2
sync_to_remote() {
    local enabled=$(yq -r '.remote.enabled // true' "$CONFIG_FILE")

    if [ "$enabled" != "true" ]; then
        log_info "Remote sync disabled, skipping"
        SYNC_SUCCESS=true
        return 0
    fi

    local bucket=$(yq -r '.remote.bucket // ""' "$CONFIG_FILE")

    if [ -z "$bucket" ]; then
        log_error "Remote bucket not configured"
        return 1
    fi

    if [ ! -f "$RCLONE_CONF" ]; then
        log_error "rclone configuration not found"
        return 1
    fi

    log_info "Syncing to B2: b2:${bucket}"

    if rclone --config="$RCLONE_CONF" sync "$BACKUP_DIR" "b2:${bucket}" --stats 15s --stats-one-line; then
        log_info "Sync to B2 complete"
        return 0
    else
        log_error "Failed to sync to B2"
        return 1
    fi
}

# Trap unexpected exits
trap 'if [ $? -ne 0 ]; then ERROR_MESSAGE="Script crashed unexpectedly"; send_discord_notification "failure"; fi' EXIT

# Main
main() {
    log_info "=== Backup started ==="

    # Create backup
    if create_backup; then
        BACKUP_SUCCESS=true
    else
        ERROR_MESSAGE="Failed to create backup archive"
        send_discord_notification "failure"
        exit 1
    fi

    # Prune old backups
    prune_backups

    # Sync to remote
    if sync_to_remote; then
        SYNC_SUCCESS=true
    else
        ERROR_MESSAGE="Failed to sync to B2"
        send_discord_notification "failure"
        exit 1
    fi

    local duration=$(($(date +%s) - START_TIME))
    log_info "=== Backup complete (${duration}s) ==="

    send_discord_notification "success"
}

main "$@"
