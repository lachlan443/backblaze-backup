# backup

Simple Docker container for automated 7z backups with Backblaze B2 sync.

## Features

- 7z compression with multi-threading
- Backblaze B2 sync via rclone
- Configurable retention (daily/weekly/monthly)
- Discord notifications
- YAML configuration with hot-reload

## Usage

```bash
docker compose up -d
```

## Manual backup

```bash
docker exec backup /backup.sh
```
