#!/usr/bin/env bash

set -e

echo "Stopping all running containers..."
podman stop -a || true

echo "Removing all containers..."
podman rm -a || true

echo "Pruning unused containers..."
podman container prune -f

echo "Pruning unused images..."
podman image prune -a -f

echo "Pruning unused volumes..."
podman volume prune -f

echo "Pruning unused networks..."
podman network prune -f

echo "Pruning build cache..."
podman builder prune -f

echo "Cleanup complete."
