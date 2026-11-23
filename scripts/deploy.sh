#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Label the two Jetsons and apply deploy/ to the k3s cluster.
# Usage:  ./scripts/deploy.sh <agx-node-name> <nano-node-name>
# e.g.:   ./scripts/deploy.sh turing-six turing-five
#         AGX Orin 64GB  = turing-six  (10.0.0.2)
#         Orin Nano 8GB  = turing-five (10.0.0.235)
# Nodes come pre-wired in this cluster: NVIDIA GPUs are advertised by the
# helm nvdp device plugin — 4 time-sliced slots per jetson (ollama uses 1).
# ---------------------------------------------------------------------------
set -euo pipefail

AGX=${1:?usage: $0 <agx-node-name> <nano-node-name>}
NANO=${2:?usage: $0 <agx-node-name> <nano-node-name>}
[ "$AGX" != "$NANO" ] || { echo "error: node names must differ" >&2; exit 1; }

echo "== cluster nodes =="
kubectl get nodes -o wide

echo "== labeling nodes =="
kubectl label node "$AGX" jetson.role- >/dev/null 2>&1 || true
kubectl label node "$NANO" jetson.role- >/dev/null 2>&1 || true
kubectl label node "$AGX" jetson.role=agx --overwrite
kubectl label node "$NANO" jetson.role=nano --overwrite

echo "== preflight: GPU allocatable =="
for N in "$AGX" "$NANO"; do
    R=$(kubectl get node "$N" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
    [ -n "$R" ] || echo "WARNING: nvidia.com/gpu is not allocatable on $N (nvdp device plugin ok?)" >&2
done

echo "== applying manifests =="
kubectl apply -k deploy

echo "== waiting for rpc pods =="
kubectl -n llama rollout status deploy/rpc-agx --timeout=240s
kubectl -n llama rollout status deploy/rpc-nano --timeout=240s

echo "== waiting for llama-server (first start: ~20 GB download + streaming to rpc nodes; up to ~20 min) =="
kubectl -n llama rollout status deploy/llama-server --timeout=1800s

IP=$(kubectl get node "$AGX" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
NP=$(kubectl -n llama get svc llama-server -o jsonpath='{.spec.ports[0].nodePort}')
echo
echo "llama-server ready at http://$IP:$NP  (NodePort: reachable on any cluster node IP)"
echo "smoke test: ./scripts/test.sh http://$IP:$NP"
echo "logs:       kubectl -n llama logs deploy/llama-server -f"
