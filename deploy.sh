#!/bin/bash
set -euo pipefail

# Configuration
REGISTRY_NAME="${REGISTRY_NAME:-asireonclawacr}"
IMAGE_NAME="${IMAGE_NAME:-openclaw}"

# Get the current full commit SHA to match what GitHub Actions uses
SHA=$(git rev-parse HEAD)
IMAGE_TAG="$REGISTRY_NAME.azurecr.io/$IMAGE_NAME:$SHA"

# These plugins are excluded from core dist (see the "files" denylist in package.json) and the
# Docker prune step reads that same list. They must be baked into the image at 755: Azure Files
# mounts the state dir as 777, and OpenClaw's discovery gate blocks world-writable plugin paths,
# so `openclaw plugins install` can never produce a loadable plugin on this deployment.
OPENCLAW_EXTENSIONS="${OPENCLAW_EXTENSIONS:-deepseek,slack,codex,perplexity}"

echo "🚀 Building AMD64 Docker image: $IMAGE_TAG"
echo "   Bundled extensions: $OPENCLAW_EXTENSIONS"
# Explicitly use linux/amd64 platform to prevent exec format errors when building from Apple Silicon
docker build --platform linux/amd64 \
  --build-arg OPENCLAW_EXTENSIONS="$OPENCLAW_EXTENSIONS" \
  -t "$IMAGE_TAG" .

echo "📤 Pushing image to Azure Container Registry..."
docker push "$IMAGE_TAG"

echo "✅ Build and push completed successfully!"
