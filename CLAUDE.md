# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Multi-node LLM inference on the home Jetson k3s cluster: `llama-server` +
one `ggml-rpc-server` pod per Jetson (CUDA), model layers split across both GPUs
by llama.cpp's **RPC backend**. Deployed via the kustomize bundle in `deploy/`.
Long-form docs: [README.md](README.md).

Original ask was "MPI"; MPI was removed from llama.cpp upstream in May 2024
(commit `d359f3092`), and on 2026-11-21 the decision (user-approved) was to use
the RPC backend on the current llama.cpp checkout instead. If a task seems to
call for "MPI" with this checkout, it means RPC. (Pre-May-2024 llama.cpp builds
with `LLAMA_MPI=ON` exist for archaeology only — they predate Qwen3.)

## Environment (fixed facts — recheck with kubectl if a task is stale)

- llama.cpp source: `./llama.cpp` (upstream `ggml-org/llama.cpp` checkout).
  **Do not patch it** — if a build issue appears, fix the Dockerfile /
  `.dockerignore` / CMake flags, not vendored source.
- k3s server: `turing-one` at `https://10.0.0.222:6443`, kubeconfig
  `~/.kube/config` (9 nodes, v1.35.x; plain `kubectl` works as-is).
  The jets are just 2 of 9 worker nodes of a shared multi-tenant homelab
  cluster (ollama, keycloak, Longhorn colocated) — keep all changes
  non-invasive: namespace-scoped, additive labels, bounded resources.
- Jetson AGX Orin 64 GB = node **turing-six** (10.0.0.2).
  Jetson Orin Nano 8 GB = node **turing-five** (10.0.0.235).
  deploy.sh labels them `jetson.role=agx|nano`; all manifests pin via that.
- Both jets run k3s with the **Docker container runtime**:
  `runtimeClassName` is unusable. GPU pods work like the (already running)
  ollama deployment: request `nvidia.com/gpu` + env
  `NVIDIA_DRIVER_CAPABILITIES=compute,utility`. No runtime class, ever.
- GPUs: **4 time-sliced `nvidia.com/gpu` slots per jet** via the existing helm
  `nvdp` device plugin. Do NOT add another device-plugin DaemonSet (would
  double-advertise). ollama already holds 1 slot on turing-six.
- NodePort **30800 is taken** (keycloak) — llama-server uses **30990**.
- Model: `Qwen/Qwen3-32B-GGUF` single file `Qwen3-32B-Q4_K_M.gguf` (~20 GB,
  ungated). bartowski mirrors may 401; prefer official repos. It's a hybrid
  thinking model — disable thinking via `chat_template_kwargs:
  {"enable_thinking": false}` or `/no_think` in the system prompt.

## Layout + commands

```
container/Dockerfile   arm64 CUDA(12.4) sm_87 build: llama-server + ggml-rpc-server
                       (API-only: LLAMA_USE_PREBUILT_UI=OFF; ccache + in-layer retries)
container/build.sh     cross-build x86→arm64 (buildx + QEMU) → *.tar.gz; JOBS=8 default
deploy/                kustomization; ALL tunables (model, -ts, ctx, kv) in 03-config.yaml
scripts/               distribute-image (docker load on jets), deploy (labels+apply+wait),
                       test (smoke), undeploy; cluster-nvidia-setup = FRESH nodes only
```

Build & run end-to-end:

```bash
TAG=0.1.0 ./container/build.sh                                   # hours under QEMU
./scripts/distribute-image.sh 0.1.0 user@10.0.0.2 user@10.0.0.235
./scripts/deploy.sh turing-six turing-five
./scripts/test.sh http://10.0.0.2:30990
```

## Gotchas (each cost a real build/deploy failure)

1. `.dockerignore` must **keep** `llama.cpp/scripts/`: the server's
   "Provisioning UI assets" step needs `scripts/ui-assets.cmake`, and it runs
   unconditionally. Symptom if dropped: `Error processing file:
   .../scripts/ui-assets.cmake` — and ninja prints an unrelated *last-running*
   object (e.g. mtmd) as the visible final line. Read the FAILED block above.
2. QEMU-emulated compilers die at high parallelism (OOM/segfault): `JOBS=8`
   default; ccache cache-mount makes failed-layer retries cheap. Don't raise
   JOBS for emulated builds.
3. `-ts` device order follows `RPC_ENDPOINTS` order (local-GPU-free
   llama-server pod is deliberate — it keeps split order deterministic).
   Set `-DLLAMA_USE_PREBUILT_UI=ON` only if the web UI is wanted (adds a
   build-time HF fetch).
4. Image shipping for docker-runtime nodes = `docker load` (not `k3s ctr`).
5. Validate changes before claiming done:
   `python3 -c "import glob,yaml; [list(yaml.safe_load_all(open(f))) for f in glob.glob('deploy/*.yaml')]"`
   and `bash -n scripts/*.sh`.
