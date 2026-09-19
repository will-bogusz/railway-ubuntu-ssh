#!/usr/bin/env bash
# Build linux/amd64 and push to GHCR. Run on a docker host (not a laptop):
#   gh auth token | docker login ghcr.io -u will-bogusz --password-stdin
#   ./build.sh                # tag defaults to 24.04-YYYYMMDD
#   ./build.sh 24.04-20260920 --push
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=ghcr.io/will-bogusz/railway-ubuntu-ssh
TAG="${1:-24.04-$(date -u +%Y%m%d)}"
PUSH="${2:-}"

docker build --platform linux/amd64 -t "$IMAGE:$TAG" .
if [ "$PUSH" = "--push" ]; then
  docker push "$IMAGE:$TAG"
  docker image inspect "$IMAGE:$TAG" --format '{{index .RepoDigests 0}}'
fi
