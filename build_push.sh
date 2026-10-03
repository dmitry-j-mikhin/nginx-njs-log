#!/bin/sh
# Builds a multi-platform image and pushes it as :latest and :<nginx version>.
# Needs a buildx builder that can build for all of $PLATFORMS, e.g. the
# containerd image store, or: docker buildx create --use

set -ex

cd "$(dirname "$0")"

REPO=${REPO:-dmikhin/nginx-njs-log}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
NGINX_VERSION=$(sed -n 's/^FROM nginx:\([0-9.]*\).*/\1/p' Dockerfile)

./test/smoke-test.sh

docker buildx build --pull --no-cache \
 --platform "$PLATFORMS" \
 --tag "$REPO:$NGINX_VERSION" \
 --tag "$REPO:latest" \
 --push .
