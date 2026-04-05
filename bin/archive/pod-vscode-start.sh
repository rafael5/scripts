f#!/usr/bin/env bash
set -e

CONTAINER_NAME="vscode"
PORT="8085"
WORKDIR="$HOME/vscode-workspace"
CONFIGDIR="$HOME/vscode-config"
PASSWORD="admin"

echo "Creating directories..."
sudo mkdir -p $WORKDIR
sudo mkdir -p $CONFIGDIR

echo "Setting permissions..."
sudo chown -R $USER:$USER $WORKDIR
sudo chown -R $USER:$USER $CONFIGDIR

echo "Pulling ARM64 VS Code server image..."
podman pull docker.io/linuxserver/code-server:latest

echo "Removing existing container if present..."
podman rm -f $CONTAINER_NAME 2>/dev/null || true

echo "Starting VS Code container..."

podman run -d \
--name $CONTAINER_NAME \
-p $PORT:8443 \
-v $WORKDIR:/config/workspace \
-v $CONFIGDIR:/config \
-e PASSWORD=$PASSWORD \
-e PUID=$(id -u) \
-e PGID=$(id -g) \
-e TZ=$(cat /etc/timezone) \
--restart unless-stopped \
docker.io/linuxserver/code-server:latest

echo ""
echo "Container started."
echo ""
echo "Access VS Code at:"
echo ""
echo "http://pi5.warg-torino.ts.net:$PORT"
echo ""
echo "Login password:"
echo "$PASSWORD"
echo ""
