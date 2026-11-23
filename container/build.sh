#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cross-build the jetson llama.cpp image (linux/arm64) from an x86 host.
#
# Usage:   TAG=0.1.0 ./container/build.sh
# Output:  llama-rpc-server-0.1.0-arm64.tar.gz  (repo root)
#
# Requires docker + buildx + QEMU binfmt. The CUDA toolchain runs under QEMU
# emulation, so expect ~1.5-3h for a clean build. For a faster, emulation-free
# build, copy the repo to the AGX Orin and run the same Dockerfile there
# without the --platform flag (the Jetson has native arm64 gcc/nvcc).
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE=${IMAGE:-llama-rpc-server}
TAG=${TAG:-0.1.0}
CUDA_BASE=${CUDA_BASE:-12.4.1}
# Parallel jobs during the emulated build. QEMU compilers crash or OOM when
# pushed wide; 8 is a safe default on a 12-core/64GB host. On a native-jetson
# build (no QEMU) you can raise this to the full core count.
JOBS=${JOBS:-8}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }
[ -d "$ROOT/llama.cpp" ] || {
    echo "error: ./llama.cpp not found - the build compiles that checkout in place" >&2
    echo "       git clone https://github.com/ggml-org/llama.cpp   (repo is gitignored)" >&2
    exit 1
}

# Install QEMU binfmt handlers for arm64 execution (idempotent).
if [ "${SKIP_BINFMT:-0}" != "1" ]; then
    docker run --privileged --rm tonistiigi/binfmt --install arm64
fi

docker buildx build \
    --platform linux/arm64 \
    --build-arg CUDA_BASE="$CUDA_BASE" \
    --build-arg JOBS="$JOBS" \
    -f container/Dockerfile \
    -t "$IMAGE:$TAG" \
    --output "type=docker,dest=$IMAGE-$TAG-arm64.tar" \
    .

gzip -f "$IMAGE-$TAG-arm64.tar"
echo
echo "Built $IMAGE-$TAG-arm64.tar.gz"
echo "Next: ./scripts/distribute-image.sh $TAG <user@agx-host> <user@nano-host>"
