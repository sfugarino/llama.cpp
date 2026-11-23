# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# llama.cpp for Jetson Orin (aarch64): CUDA + RPC backend
# Contains: llama-server (HTTP API / orchestrator) and ggml-rpc-server
# (exposes the Jetson's GPU to remote llama-server instances).
#
# Built for linux/arm64 via container/build.sh (docker buildx + QEMU).
# Both Jetson Orin variants are compute capability 8.7 (sm_87, Ampere).
# Base CUDA 12.4 runs on JetPack 6.x via CUDA minor-version compatibility
# (JetPack 6.0 ships a 12.2 driver). For a JP 6.0 box with strict
# tool-alignment requirements, rebuild with CUDA_BASE=12.2.2.
# ---------------------------------------------------------------------------

ARG CUDA_BASE=12.4.1
FROM nvidia/cuda:${CUDA_BASE}-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ccache libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/llama.cpp
COPY llama.cpp/ .

# QEMU-emulated compilers die occasionally (OOM or segfault) when run too
# wide: 12 parallel emulated cc1plus/nvcc processes can exhaust RAM or trip
# binfmt instability. Mitigations: cap jobs (JOBS build-arg), ccache backed
# by a cache mount (completed objects survive failed RUN layers), and retry
# the build inside the layer (succeeded objects persist in /out/build).
ARG JOBS=8
ENV CCACHE_DIR=/root/.ccache
# LLAMA_USE_PREBUILT_UI=OFF: no npm in the image; without this the server
# build would download the prebuilt web UI from a HF bucket at build time.
# The build then embeds an empty UI and llama-server is API-only.
# Flip to ON to include the built-in web UI (build-time network required).
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_CUDA=ON \
        -DGGML_RPC=ON \
        -DCMAKE_CUDA_ARCHITECTURES=87 \
        -DLLAMA_BUILD_IS_DEV=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build build --target llama-server ggml-rpc-server -- -j"$JOBS" \
    || (echo "== build failed once (transient QEMU error?) - retrying ==" \
        && cmake --build build --target llama-server ggml-rpc-server -- -j"$JOBS") \
    || (echo "== retry 2 ==" \
        && cmake --build build --target llama-server ggml-rpc-server -- -j"$JOBS")

# ---------------------------------------------------------------------------
# Runtime: CUDA runtime libraries ship in the image; the driver (libcuda) is
# injected by the nvidia container runtime on the nodes.
# ---------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_BASE}-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libcurl4 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/llama.cpp/build/bin/llama-server    /usr/local/bin/
COPY --from=builder /src/llama.cpp/build/bin/ggml-rpc-server /usr/local/bin/

EXPOSE 8080 50052
