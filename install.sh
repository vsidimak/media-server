#!/bin/bash
# install.sh - Initial server setup script

set -e

# === CONFIGURATION ===
USER_HOME="/home/$(whoami)"
PROJECT_DIR="$USER_HOME/media-server"
DATA_DIR="$PROJECT_DIR/data"

# $DATA_DIR/
# ├── downloads/
# │   ├── qbittorrent/
# │   │   ├── incomplete/
# │   │   └── complete/
# ├── media/
# │   ├── movies/
# │   └── series/
# ├── radarr/
# ├── sonarr/
# ├── jackett/
# ├── jellyfin/
# └── qbittorrent/

# Summary of Shared Volumes Between Services
# Volume	Services using it
# $DATA_DIR/downloads/qbittorrent	qBittorrent (full path)
# $DATA_DIR/downloads/qbittorrent/complete	Radarr, Sonarr, Jackett
# $DATA_DIR/media/movies	Radarr (write), Jellyfin (read)
# $DATA_DIR/media/series	Sonarr (write), Jellyfin (read)

CONFIG_DIR="$PROJECT_DIR/config"
SERVICES_DIR="$PROJECT_DIR/services"
echo "🔍 Loading environment variables..."
set -o allexport
source ".env"
set +o allexport

# --- Validate required environment variables ---
REQUIRED_VARS=(
    NORDVPN_USERNAME
    NORDVPN_PASSWORD
)
# === STEP 1: Update & install system packages ===
echo "🔍 Validating environment variables..."
missing_vars=0
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "❌ Missing: $var"
    missing_vars=1
  fi
done
if [[ "$missing_vars" -eq 1 ]]; then
    echo "❌ Aborting due to missing variables in .env"
    exit 1
fi

echo "✅ Environment validated."

# === STEP 1: Update & install system packages ===
echo "🔧 Updating system..."
sudo apt update && sudo apt upgrade -y

# === STEP 2: Install Docker & Docker Compose ===
echo "🐳 Installing Docker & Docker Compose..."
sudo apt install -y docker.io docker-compose
sudo systemctl enable docker --now
# Below needed if need to run docker commands without sudo
# sudo usermod -aG docker "$USER"

# === STEP 3: Create directories ===
echo "📁 Creating directories..."
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$SERVICES_DIR"

# === STEP 4: Write Compose files ===
echo "📝 Writing docker-compose files..."

# Infra (Pi-hole, Traefik)
cat > "$SERVICES_DIR/infra.yml" <<EOF
version: '3.8'
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    environment:
      - WEBPASSWORD=changeme
    volumes:
      - \$CONFIG_DIR/pihole:/etc/pihole
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80"
    restart: unless-stopped

  traefik:
    image: traefik:v2.11
    container_name: traefik
    command:
      - "--api.insecure=true"
      - "--providers.docker"
    ports:
      - "443:443"
      - "8080:8080"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    restart: unless-stopped
EOF

# Downloader stack behind VPN (qBittorrent, Sonarr, Radarr, Jackett)
cat > "$SERVICES_DIR/download.yml" <<EOF
version: '3.8'
services:
  nordvpn:
    image: bubuntux/nordvpn
    container_name: nordvpn
    cap_add:
      - NET_ADMIN
    environment:
      - USER=$NORDVPN_USERNAME
      - PASS=$NORDVPN_PASSWORD
      - CONNECT=Spain
      - TECHNOLOGY=NordLynx
      - NETWORK=192.168.178.0/24
    volumes:
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent
    container_name: qbittorrent
    network_mode: "service:nordvpn"
    depends_on:
      - nordvpn
    environment:
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
    volumes:
      - $DATA_DIR/qbittorrent:/config
      - $DATA_DIR/downloads/qbittorrent:/downloads
    restart: unless-stopped

  jackett:
    image: linuxserver/jackett
    container_name: jackett
    network_mode: "service:nordvpn"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $DATA_DIR/jackett:/config
      - $DATA_DIR/downloads/qbittorrent/complete:/downloads  # so you can test/search manually if needed
    restart: unless-stopped

  radarr:
    image: linuxserver/radarr
    container_name: radarr
    network_mode: "service:nordvpn"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $DATA_DIR/radarr:/config
      - $DATA_DIR/downloads/qbittorrent/complete:/downloads
      - $DATA_DIR/media/movies:/movies
    restart: unless-stopped

  sonarr:
    image: linuxserver/sonarr
    container_name: sonarr
    network_mode: "service:nordvpn"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $DATA_DIR/sonarr:/config
      - $DATA_DIR/downloads/qbittorrent/complete:/downloads
      - $DATA_DIR/media/series:/series
    restart: unless-stopped
EOF

# Media stack (Jellyfin)
cat > "$SERVICES_DIR/media.yml" <<EOF
version: '3.8'
services:
 jellyfin:
    image: jellyfin/jellyfin
    container_name: jellyfin
    ports:
      - "8096:8096"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - $DATA_DIR/jellyfin:/config
      - $DATA_DIR/media/movies:/media/movies
      - $DATA_DIR/media/series:/media/series
    devices:
      # - /dev/dri:/dev/dri  # Optional: For Intel GPU HW transcoding
    restart: unless-stopped
EOF


# === STEP 5: Install Flask and setup management API ===
# echo "🌐 Installing Flask API for container control..."
# sudo apt install -y python3-pip
# pip3 install flask docker

# cat > "$PROJECT_DIR/manage_api.py" <<EOF
# from flask import Flask, jsonify, request
# import docker
# import os

# app = Flask(__name__)
# client = docker.from_env()

# @app.route('/containers', methods=['GET'])
# def list_containers():
#     containers = client.containers.list(all=True)
#     return jsonify([{c.name: c.status} for c in containers])

# @app.route('/containers/<name>/start', methods=['POST'])
# def start_container(name):
#     client.containers.get(name).start()
#     return jsonify({"status": "started", "container": name})

# @app.route('/containers/<name>/stop', methods=['POST'])
# def stop_container(name):
#     client.containers.get(name).stop()
#     return jsonify({"status": "stopped", "container": name})

# @app.route('/containers/<name>/restart', methods=['POST'])
# def restart_container(name):
#     client.containers.get(name).restart()
#     return jsonify({"status": "restarted", "container": name})

# @app.route('/shutdown', methods=['POST'])
# def shutdown_system():
#     os.system('shutdown now')
#     return jsonify({"status": "shutting down"})

# if __name__ == '__main__':
#     app.run(host='0.0.0.0', port=5000)
# EOF

# # === STEP 6: Create systemd service to auto-start Flask API ===
# echo "🔁 Creating systemd service for Flask API..."
# mkdir -p "$USER_HOME/.config/systemd/user"
# cat > "$USER_HOME/.config/systemd/user/manage_api.service" <<EOF
# [Unit]
# Description=Flask Docker Management API

# [Service]
# ExecStart=/usr/bin/python3 $PROJECT_DIR/manage_api.py
# WorkingDirectory=$PROJECT_DIR
# Restart=always
# Environment=PYTHONUNBUFFERED=1

# [Install]
# WantedBy=default.target
# EOF

# systemctl --user daemon-reexec
# systemctl --user daemon-reload
# systemctl --user enable manage_api.service
# systemctl --user start manage_api.service

# === STEP 7: Launch stacks ===
echo "🚀 Launching stacks..."
# docker compose -f "$SERVICES_DIR/infra.yml" up -d
docker compose -f "$SERVICES_DIR/dl.yml" up -d
docker compose -f "$SERVICES_DIR/media.yml" up -d

# # === STEP 8: Add diagnostic validation script ===
# echo "📋 Creating diagnostic script..."
# cat > "$PROJECT_DIR/validate.sh" <<EOF
# #!/bin/bash

# echo "=== System Diagnostic Check ==="
# echo "Hostname: \$(hostname)"
# echo "Date: \$(date)"
# echo "Uptime: \$(uptime -p)"
# echo

# # Docker checks
# echo "Docker version: \$(docker --version)"
# echo "Docker Compose version: \$(docker-compose --version)"
# echo "Containers status:"
# docker ps -a --format "table {{.Names}}\t{{.Status}}"
# echo

# # Flask service check
# echo -n "Flask API service status: "
# systemctl --user is-active manage_api.service || echo "inactive"
# echo

# # Mounted volumes
# echo "Mounted volumes:"
# df -h | grep "media-server"
# echo

# echo "✅ Diagnostic completed."
# EOF
# chmod +x "$PROJECT_DIR/validate.sh"

# === STEP 9: Ask about diagnostic cron setup ===
read -p "🔄 Enable diagnostics every 30 minutes? (y/n): " enable_diag
if [[ "$enable_diag" == "y" ]]; then
    (crontab -l 2>/dev/null; echo "*/30 * * * * $PROJECT_DIR/validate.sh >> $PROJECT_DIR/logs/diagnostic.log 2>&1") | crontab -
    echo "✅ Diagnostics cron job installed."
else
    echo "⏭️ Skipping diagnostics cron job."
fi

# === STEP 10: Ask about restoring from backup ===
read -p "♻️ Restore from existing config backup? (y/n): " do_restore
if [[ "$do_restore" == "y" ]]; then
    read -p "📁 Enter path to backup archive: " backup_path
    "$BASE_DIR/restore.sh" "$backup_path"
fi

# === STEP 11: Finished ===
echo "✅ Server setup complete. Access services via LAN IP."
echo "Flask API available on port 5000 for container control."
echo "You may need to logout and login again for Docker permissions to apply."
echo "Run ./validate.sh anytime to check system and container health."



