#!/bin/bash
set -e

BACKUP_ARCHIVE="$1"

if [[ ! -f "$BACKUP_ARCHIVE" ]]; then
    echo "❌ Backup file not found: $BACKUP_ARCHIVE"
    exit 1
fi

echo "♻️ Restoring from backup: $BACKUP_ARCHIVE"
tar -xzvf "$BACKUP_ARCHIVE" -C "$HOME/media-server/data"

echo "✅ Restore completed. Restarting containers..."
docker compose -f "$HOME/media-server/docker-compose.media.yml" up -d