#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ship the built image to each node. The Jetsons (turing-five/six) run k3s
# with the Docker container runtime, so the image must land in Docker's
# store (`docker load`), not the containerd k8s.io namespace.
# Containerd-backed nodes are handled via a k3s ctr fallback.
#
# Usage:  ./scripts/distribute-image.sh 0.1.0 <user@node1> <user@node2>
# e.g.:   ./scripts/distribute-image.sh 0.1.0 user@10.0.0.2 user@10.0.0.235
# ---------------------------------------------------------------------------
set -euo pipefail

TAG=${1:?usage: $0 <tag> <user@node1> <user@node2> ...}
shift
IMAGE=${IMAGE:-llama-rpc-server}
TAR="$IMAGE-$TAG-arm64.tar.gz"

[ -f "$TAR" ] || { echo "error: $TAR not found - run container/build.sh first" >&2; exit 1; }
[ $# -ge 1 ] || { echo "error: no ssh targets given" >&2; exit 1; }

for NODE in "$@"; do
    echo "== $NODE: upload + load $TAR =="
    scp "$TAR" "$NODE:/tmp/"
    if ssh "$NODE" "docker load -i /tmp/$TAR" 2>/dev/null; then
        ssh "$NODE" "rm -f /tmp/$TAR && docker images $IMAGE --format '{{.Repository}}:{{.Tag}}'"
    elif ssh "$NODE" "sudo docker load -i /tmp/$TAR"; then
        ssh "$NODE" "rm -f /tmp/$TAR && sudo docker images $IMAGE --format '{{.Repository}}:{{.Tag}}'"
    elif ssh "$NODE" "sudo k3s ctr images import /tmp/$TAR"; then
        # containerd-backed node (k3s without --docker)
        ssh "$NODE" "rm -f /tmp/$TAR && sudo crictl images | grep $IMAGE || true"
    else
        echo "error: could not load image on $NODE (docker and k3s ctr both failed)" >&2
        exit 1
    fi
done
echo
echo "done - image $IMAGE:$TAG loaded on all nodes"
