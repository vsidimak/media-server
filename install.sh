#!/bin/bash
# install.sh - Initial server setup script

set -e

# === CONFIGURATION ===
USER_HOME="/home/$(whoami)"
BASE_DIR="/srv"
PROJECT_DIR="$BASE_DIR/media-server"
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

LOG_PREFIX="[media-server]"

log() {
  echo "$LOG_PREFIX $@"
}

create_snapshot() {
    local label="$1"
    echo "📸 Creating Timeshift snapshot: $label"
    sudo timeshift --create --comments "$label" --tags O
}

CONFIG_DIR="$PROJECT_DIR/config"
SERVICES_DIR="$PROJECT_DIR/services"
log "🔍 Loading environment variables..."
set -o allexport
source ".env"
set +o allexport

# --- Validate required environment variables ---
REQUIRED_VARS=(
    NORDVPN_PRIVATE_KEY
)
# === STEP 1: Update & install system packages ===
log "🔍 Validating environment variables..."
missing_vars=0
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    log "❌ Missing: $var"
    missing_vars=1
  fi
done
if [[ "$missing_vars" -eq 1 ]]; then
    log "❌ Aborting due to missing variables in .env"
    exit 1
fi

log "✅ Environment validated."

# === STEP 1: Update & install system packages ===
log "🔧 Updating system..."
sudo apt update && sudo apt upgrade -y
# timeshift for system snapshots
# sudo apt install timeshift -y



# Initial clean snapshot
create_snapshot "Clean system after install and update"

# === STEP 2: Install Docker & Docker Compose ===
log "🐳 Installing Docker & Docker Compose..."
# === STEP 2.1: Install Docker Engine ===
sudo apt install -y docker.io

# Enable and start Docker service
sudo systemctl enable docker --now

# === STEP 2.2: Install Docker Compose v2 (as plugin) ===
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
# Below needed if need to run docker commands without sudo
# sudo usermod -aG docker "$USER"


# Snapshot after installing docker
# create_snapshot "Installed Docker and Docker Compose"

# === STEP 3: Create directories ===
log "📁 Creating directories..."
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$SERVICES_DIR"


# # === STEP: NordVPN ===
# sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

# # Enable auto-connect on boot
# nordvpn set autoconnect enabled

# # Use NordLynx (faster, modern protocol)
# nordvpn set technology nordlynx

# # Whitelist local LAN access (for 192.168.0.0/16, e.g. 192.168.1.x)
# nordvpn whitelist add subnet 192.168.178.0/24
# nordvpn whitelist add subnet 77.109.102.145/32
# # Enable kill switch (blocks internet if VPN is down)
# nordvpn set killswitch enabled
# # login
# nordvpn login --token $NORDVPN_TOKEN

# === STEP 4: Write Compose files ===
log "📝 Writing docker-compose files..."

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

# Home assistant
cat "$SERVICES_DIR/home.yml" <<EOF
version: '3.8'
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    volumes:
      - ${DATA_DIR}/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=Europe/Berlin
    restart: unless-stopped
    network_mode: host
    privileged: true # Required for full hardware access (e.g., USB dongles)
EOF

# Downloader stack behind VPN (NordVPN, qBittorrent, Jackett)
cat > "$SERVICES_DIR/download.yml" <<EOF
version: '3.8'
services:
  nordlynx:
    image: ghcr.io/bubuntux/nordlynx
    hostname: nordlynx
    container_name: nordlynx
    cap_add:
      - NET_ADMIN                             # required
      - SYS_MODULE                            # maybe
    environment:
      - PRIVATE_KEY=$NORDVPN_PRIVATE_KEY                # required
      - QUERY=filters\[servers_groups\]\[identifier\]=legacy_p2p
      - NET_LOCAL=172.19.0.0/16
      - TZ=Europe/Berlin
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1   # maybe
      - net.ipv4.conf.all.rp_filter=2        # maybe; set reverse path filter to loose mode
      - net.ipv6.conf.all.disable_ipv6=1
    restart: unless-stopped
    networks:
      - media_net

  # nordvpn:
  #   image: bubuntux/nordvpn
  #   container_name: nordvpn
  #   cap_add:
  #     - NET_ADMIN
  #     - NET_RAW
  #   environment:
  #     - TOKEN=$NORDVPN_TOKEN
  #     - CONNECT=Spain
  #     - TECHNOLOGY=NordLynx
  #     - NETWORK=172.19.0.0/16
  #   volumes:
  #     - /dev/net/tun:/dev/net/tun
  #   devices:
  #     - /dev/net/tun
  #   sysctls:
  #     - net.ipv4.conf.all.src_valid_mark=1
  #   networks:
  #     - media_net
  #   restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent
    container_name: qbittorrent
    network_mode: "container:nordlynx"
    depends_on: 
      - nordlynx
    environment:
      - PUID=1000
      - PGID=1000
      - WEBUI_PORT=8080
      - TORRENTING_PORT=6881
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    volumes:
      - $DATA_DIR/qbittorrent:/config
      - $DATA_DIR/downloads/qbittorrent:/downloads
    restart: unless-stopped

networks:
  media_net:
    external: true
EOF

# *arr media stack (Radarr, Sonarr, Prowlass, Overseerr)
cat > "$SERVICES_DIR/media.yml" <<EOF
version: '3.8'
services:
  overseerr:
    image: sctx/overseerr:latest
    container_name: overseerr
    environment:
      - LOG_LEVEL=debug
      - TZ=Europe/Berlin
      - PORT=5055 #optional
    ports:
      - 5055:5055
    volumes:
      - $DATA_DIR/overseerr:/app/config
    restart: unless-stopped
    networks:
      - media_net

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Berlin
    volumes:
      - $DATA_DIR/prowlarr:/config
    ports:
      - 9696:9696
    restart: unless-stopped
    networks:
      - media_net

  radarr:
    image: linuxserver/radarr
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Berlin
    volumes:
      - $DATA_DIR/radarr:/config
      - $DATA_DIR/downloads/qbittorrent/complete:/downloads
      - $DATA_DIR/media/movies:/movies
    ports:
      - "7878:7878"
    restart: unless-stopped
    networks:
      - media_net

  sonarr:
    image: linuxserver/sonarr
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Berlin
    volumes:
      - $DATA_DIR/sonarr:/config
      - $DATA_DIR/downloads/qbittorrent/complete:/downloads
      - $DATA_DIR/media/series:/series
    ports:
      - "8989:8989"
    restart: unless-stopped
    networks:
      - media_net

  plex:
    image: linuxserver/plex
    container_name: plex
    environment:
      - PUID=1000
      - PGID=1000
      - VERSION=docker
      - TZ=Europe/Berlin
      # Optional: claim token for first-time setup, get from https://www.plex.tv/claim
      # - PLEX_CLAIM=your_plex_claim_token
    # network_mode: host # Needed for DLNA, Chromecast, local discovery
    volumes:
      - ${DATA_DIR}/plex:/config
      - ${DATA_DIR}/media/movies:/movies
      - ${DATA_DIR}/media/series:/series
    restart: unless-stopped
    networks:
      - media_net

  # jellyfin:
  #   image: jellyfin/jellyfin
  #   container_name: jellyfin
  #   ports:
  #     - "8096:8096"
  #   environment:
  #     - PUID=1000
  #     - PGID=1000
  #     - TZ=Europe/Berlin
  #   volumes:
  #     - $DATA_DIR/jellyfin:/config
  #     - $DATA_DIR/media/movies:/media/movies
  #     - $DATA_DIR/media/series:/media/series
  #   # devices:
  #     # - /dev/dri:/dev/dri  # Optional: For Intel GPU HW transcoding
  #   restart: unless-stopped
  
networks:
  media_net:
    external: true
EOF

# Home Assistant
cat > "$SERVICES_DIR/home.yml" <<EOF
version: '3.8'
services:
  homeassistant:
    container_name: homeassistant
    image: "ghcr.io/home-assistant/home-assistant:stable"
    volumes:
      - $DATA_DIR/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    restart: unless-stopped
    privileged: true
    network_mode: host
EOF

# === STEP 7: Launch stacks ===
log "Creating docker network..."
docker network create media_net
log "🚀 Launching stacks..."
docker compose -f "$SERVICES_DIR/download.yml" -f "$SERVICES_DIR/media.yml" up -d
# docker compose -f "$SERVICES_DIR/download.yml" -f "$SERVICES_DIR/media.yml" -f "$SERVICES_DIR/home.yml" up -d

# === STEP 8: Add diagnostic validation script ===
log "📋 Creating diagnostic script..."
cat > "$PROJECT_DIR/validate.sh" <<EOF
#!/bin/bash

echo "=== System Diagnostic Check ==="
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo "Uptime: $(uptime -p)"
echo 

# Docker checks
echo "Docker version: $(docker --version)"
if command -v docker-compose &>/dev/null; then
  echo "Docker Compose version: $(docker-compose --version)"
elif docker compose version &>/dev/null; then
  echo "Docker Compose version: $(docker compose version)"
else
  echo "Docker Compose is not installed."
fi
echo 
echo "Containers status:"
docker ps -a --format "table {{.Names}}\t{{.Status}}"
echo 

# Mounted volumes
echo "Mounted volumes:"
df -h | grep "media-server"
echo 

echo "✅ Diagnostic completed."
EOF
chmod +x "$PROJECT_DIR/validate.sh"



# # === STEP 9: Ask about diagnostic cron setup ===
# read -p "🔄 Enable diagnostics every 30 minutes? (y/n): " enable_diag
# if [[ "$enable_diag" == "y" ]]; then
#     (crontab -l 2>/dev/null; log "*/30 * * * * $PROJECT_DIR/validate.sh >> $PROJECT_DIR/logs/diagnostic.log 2>&1") | crontab -
#     log "✅ Diagnostics cron job installed."
# else
#     log "⏭️ Skipping diagnostics cron job."
# fi

# # === STEP 10: Ask about restoring from backup ===
# read -p "♻️ Restore from existing config backup? (y/n): " do_restore
# if [[ "$do_restore" == "y" ]]; then
#     read -p "📁 Enter path to backup archive: " backup_path
#     "$BASE_DIR/restore.sh" "$backup_path"
# fi

# === STEP 11: Finished ===
log "✅ Server setup complete. Access services via LAN IP."
log "Flask API available on port 5000 for container control."
log "You may need to logout and login again for Docker permissions to apply."
log "Run ./validate.sh anytime to check system and container health."



