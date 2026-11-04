#!/bin/sh

set -e

# Builds the image and starts the detached VPN service. No VPN credentials are needed here:
# authenticate afterwards with "docker exec -it openconnect-ocproxy vpn-login".
# Usage: sh build_and_run_locally.sh [env-file]   (default: .env next to this script)
# The env file is parsed by Docker Compose, never sourced as shell code, and holds nonsecret settings only.

SCRIPT=$(readlink -f "$0")
SCRIPT_PATH=$(dirname "$SCRIPT")
ENV_FILE="${SCRIPT_PATH}/${1:-.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: env file not found at $ENV_FILE. Copy .env.example to .env and edit it."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Please start Docker and try again."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Error: Docker Compose v2 ('docker compose') is required."
    exit 1
fi

cd "$SCRIPT_PATH"

echo "[x] Building and starting the service..."
docker compose --env-file "$ENV_FILE" up -d --build

echo "[x] Service started and waiting for authentication. Next steps:"
echo "      docker exec -it openconnect-ocproxy vpn-login     # authenticate (repeat to renew an expired session)"
echo "      docker exec openconnect-ocproxy vpn-status        # tunnel state"
echo "      docker logs --tail 30 openconnect-ocproxy"
echo "[x] Script finished successfully at $(date)"
