#!/bin/sh

set -e

# Ensure that the script is called with exactly one argument (the env file)
if [ "$#" -ne 1 ]; then
    echo "Usage: sh $0 <env-file>"
    exit 1
fi

SCRIPT=$(readlink -f "$0")
SCRIPT_PATH=$(dirname "$SCRIPT")
ENV_FILE="${SCRIPT_PATH}/$1"

# Check if the environment file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: File with envs not found at $ENV_FILE."
    exit 1
fi

# Source the environment variables
. "$ENV_FILE"

# Check if Dockerfile exists
if [ ! -f Dockerfile ]; then
    echo "Error: Dockerfile not found in the current directory."
    exit 1
fi

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Please start Docker and try again."
    exit 1
fi

# Check if DOCKER_IMAGE_VERSION is set
if [ -z "${DOCKER_IMAGE_VERSION}" ]; then
    echo "Error: DOCKER_IMAGE_VERSION is not set in $ENV_FILE. Example: '1.0.0'"
    exit 1
fi

# Check internet connection
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Error: Network is not available. Please check your connection."
    exit 1
fi

# Define the base image name to avoid repetition
IMAGE_NAME="ghcr.io/matteosecli/openconnect-ocproxy"

# Component versions, used as additional tags
ALPINE_VERSION=$(sed -n 's/^FROM alpine:\(.*\)/\1/p' Dockerfile)
OPENCONNECT_VERSION=$(sed -n 's/^ARG OPENCONNECT_VERSION=//p' Dockerfile)
OCPROXY_VERSION=$(sed -n 's/^ARG OCPROXY_VERSION=v\?//p' Dockerfile)
TAGS="latest ${DOCKER_IMAGE_VERSION} openconnect-${OPENCONNECT_VERSION} ocproxy-${OCPROXY_VERSION} alpine-${ALPINE_VERSION}"

echo "[x] Building images..."

# One image name for all architectures: per-arch images carry temporary arch tags, public tags point to the multi-arch manifest
for ARCH in arm64 amd64; do
    PLATFORM="linux/${ARCH}"
    [ "$ARCH" = "arm64" ] && PLATFORM="linux/arm64/v8"
    echo "[x] Build and push image for ${PLATFORM}..."
    docker build -t ${IMAGE_NAME}:${DOCKER_IMAGE_VERSION}-${ARCH} --no-cache --platform ${PLATFORM} .
    docker push ${IMAGE_NAME}:${DOCKER_IMAGE_VERSION}-${ARCH}
done

echo "[x] Creating and pushing multi-arch manifests..."
for TAG in ${TAGS}; do
    docker buildx imagetools create -t ${IMAGE_NAME}:${TAG} \
        ${IMAGE_NAME}:${DOCKER_IMAGE_VERSION}-arm64 \
        ${IMAGE_NAME}:${DOCKER_IMAGE_VERSION}-amd64
done

echo "[x] Done! Script finished successfully at $(date)"
