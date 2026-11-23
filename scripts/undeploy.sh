#!/usr/bin/env bash
# Remove the llama deployment from the cluster.
# Model files remain in /opt/llama-models on the AGX host; rm there manually.
set -euo pipefail
kubectl delete -k deploy --ignore-not-found=true
kubectl delete namespace llama --ignore-not-found=true --wait=false
echo "undeployed (namespace deletion runs in background)"
