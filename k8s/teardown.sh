#!/bin/bash
set -e

export DOCKER_HOST="unix:///Users/leemingi/.orbstack/run/docker.sock"
export KIND_EXPERIMENTAL_PROVIDER=docker

echo ">>> Deleting kind cluster 'cosmos-testnet'..."
kind delete cluster --name cosmos-testnet
echo ">>> Done."
