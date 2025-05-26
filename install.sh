#!/usr/bin/env bash

# install_n8n.sh
# A script to deploy n8n on Ubuntu Server with Docker, Docker Compose, Traefik reverse proxy
# featuring Let's Encrypt SSL, basic auth, IP whitelisting, health checks, backups, and resilience.

set -euo pipefail
IFS=$'\n\t'

# ----- CONFIGURATION -----
# Prompt for required values
read -rp "Enter your domain for n8n (e.g. n8n.example.com): " N8N_DOMAIN
read -rp "Enter your e-mail for Let's Encrypt notifications: " EMAIL
read -rp "Set HTTP basic auth username: " AUTH_USER
read -rsp "Set HTTP basic auth password: " AUTH_PASS
echo
read -rp "Enter comma-separated IPs/CIDRs to whitelist (e.g. 203.0.113.0/24,198.51.100.42) or leave empty: " IP_WHITELIST

# Paths
BASE_DIR="/opt/n8n"
DATA_DIR="$BASE_DIR/data"
BACKUP_DIR="$BASE_DIR/backups"
TRAEFIK_DIR="$BASE_DIR/traefik"

# Docker compose file path
docker_compose_file="$BASE_DIR/docker-compose.yml"

# Ensure script runs as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi

# Update & install prerequisites
echo "Updating and installing prerequisites..."
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

# Install Docker
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io
fi

# Install Docker Compose plugin
if ! docker compose version &> /dev/null; then
  echo "Installing Docker Compose plugin..."
  apt install -y docker-compose-plugin
fi

# Create necessary directories
echo "Setting up directory structure under $BASE_DIR..."
mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$TRAEFIK_DIR/acme"
chown -R root:root "$BASE_DIR"

# Create .env file
env_file="$BASE_DIR/.env"
cat > "$env_file" <<EOF
# Environment variables for Docker Compose
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${AUTH_PASS}
N8N_HOST=${N8N_DOMAIN}
EOF

# Prepare Traefik static config (traefik.yaml)
cat > "$TRAEFIK_DIR/traefik.yaml" <<EOF
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${EMAIL}"
      storage: "/acme/acme.json"
      httpChallenge:
        entryPoint: web
EOF
chmod 600 "$TRAEFIK_DIR/acme/acme.json"

# Create dynamic configuration for middleware
cat > "$TRAEFIK_DIR/dynamic.yaml" <<EOF
http:
  middlewares:
    n8n-auth:
      basicAuth:
        users:
          - "${AUTH_USER}:{sha256}${AUTH_PASS}"  # For bcrypt/sha or use htpasswd tool for stronger hashing
    ip-whitelist:
      ipWhiteList:
        sourceRange:
          - "${IP_WHITELIST}" # blank disables
EOF

# Generate Docker Compose file
cat > "$docker_compose_file" <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:v2.14
    command:
      - --configFile=/etc/traefik/traefik.yaml
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "$TRAEFIK_DIR/traefik.yaml:/etc/traefik/traefik.yaml:ro"
      - "$TRAEFIK_DIR/acme/acme.json:/acme/acme.json"
      - "$TRAEFIK_DIR/dynamic.yaml:/etc/traefik/dynamic.yaml:ro"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    restart: always

  n8n:
    image: n8nio/n8n:latest
    env_file:
      - .env
    environment:
      - TZ=UTC
    volumes:
      - "$DATA_DIR:/home/node/.n8n"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.routers.n8n.middlewares=n8n-auth@file,ip-whitelist@file"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: always

EOF

# Deploy stack
echo "Bringing up containers using Docker Compose..."
docker compose -f "$docker_compose_file" up -d

# Setup systemd service for resilience
service_file="/etc/systemd/system/n8n.service"
cat > "$service_file" <<EOF
[Unit]
Description=n8n automation service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$BASE_DIR
ExecStartPre=/usr/bin/docker compose pull
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n.service
systemctl start n8n.service

# Create backup script
backup_script="$BASE_DIR/backup_n8n.sh"
cat > "$backup_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TIMESTAMP=$(date +"%Y%m%dT%H%M%S")
BACKUP_PATH="$BACKUP_DIR/n8n_backup_$TIMESTAMP.tar.gz"

echo "Creating backup at $BACKUP_PATH..."
tar czf "$BACKUP_PATH" -C "$DATA_DIR" .
echo "Backup completed: $BACKUP_PATH"
EOF
chmod +x "$backup_script"

# Cron job for nightly backups at 3am
(crontab -l 2>/dev/null; echo "0 3 * * * ${backup_script}") | crontab -

# Cron for weekly OS security updates (Sunday 4am)
(crontab -l 2>/dev/null; echo "0 4 * * 0 apt update && apt upgrade -y") | crontab -

# Final message
echo "n8n has been installed and deployed successfully!"
echo "Access your instance at: https://${N8N_DOMAIN}"
echo "Backups stored in: ${BACKUP_DIR}"
