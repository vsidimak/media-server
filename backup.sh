#!/bin/bash
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$HOME/media-backups"
TARGET="$BACKUP_DIR/media_config_$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "🔄 Backing up config directories..."
tar -czvf "$TARGET" \
    -C "$HOME/media-server/data" \
    radarr sonarr jackett jellyfin

echo "✅ Backup saved to $TARGET"