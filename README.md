# Jetson k3s LLM — distributed llama.cpp over 2 nodes

Distributed `llama-server` on the home k3s cluster: one orchestrator pod holds
the GGUF and serves an OpenAI-compatible HTTP API; one `ggml-rpc-server` pod per
Jetson exposes its GPU; llama.cpp's **RPC backend** splits the model's layers
across both GPUs. Same code path works when the model doesn't fit one node.

```
                        k3s cluster @ 10.0.0.<K3S_API>
  +------------------------------------------------------------+
  |  llama-server pod  (@ turing-six, no GPU, orchestrator)    |
  |    -m Qwen3-32B-Q4_K_M  -ngl 999  -ts 7,1                  |
  |    LLAMA_ARG_RPC=rpc-agx:50052,rpc-nano:50052              |
  |        |  rpc  (tensor streams + activations)              |
  |        +--> rpc-agx  pod  @ turing-six  (AGX, 7/8 weights) |
  |        +--> rpc-nano pod  @ turing-five (Nano, 1/8 weights)|
  +------------------------------------------------------------+
            ^ NodePort 30990 -> /v1/chat/completions
```

## Quick start

```bash
TAG=0.1.0 ./container/build.sh                                    # 1. build (x86, ~hours)
./scripts/distribute-image.sh 0.1.0 user@10.0.0.<AGX_IP> user@10.0.0.<NANO_IP> # 2. ship to both jets
./scripts/deploy.sh turing-six turing-five                        # 3. apply + wait
./scripts/test.sh http://10.0.0.<AGX_IP>:30990                           # 4. smoke test
```

## Prerequisites

- **llama.cpp source checkout** at `./llama.cpp` — the container build compiles
  that tree verbatim (`container/Dockerfile` copies `llama.cpp/` into the image).
  It is deliberately NOT tracked by this repo's git (see `.gitignore`); fetch it
  into the repo root before building:

  ```bash
  git clone https://github.com/ggml-org/llama.cpp
  ```

  This deployment was built+tested against commit `e6d624b9a` (2026-11-21 tip).
  Any recent commit works — it must include the RPC backend (`GGML_RPC`, present
  since early 2024) and Qwen3 support (since early 2025).
- x86 build host with docker + buildx
- kubectl configured against the cluster (`~/.kube/config` -> 10.0.0.<K3S_API> works)
- SSH access to the jets: `user@10.0.0.<AGX_IP>` (turing-six, AGX) and
  `user@10.0.0.<NANO_IP>` (turing-five, Nano)
- Disk on turing-six: ~25 GB for the model + ~2 GB for the image
- Optional: HF mirror override — edit `MODEL_URL` in `deploy/03-config.yaml`

## Step details

### 1 - Build (x86, cross-arch)

```bash
TAG=0.1.0 ./container/build.sh
```

- Produces `llama-rpc-server-$TAG-arm64.tar.gz` in the repo root.
- QEMU runs the CUDA toolchain under emulation - slow but correct (expect
  hours; nvcc kernel steps are the tail). ccache + a cache mount make
  failed-layer retries cheap, and the build retries itself twice in-layer.
- Parallelism: `JOBS=8` default (QEMU compilers crash at `-j12`). On a native
  Jetson build (`docker build` directly on the AGX, no `--platform` flag)
  raise it to the core count.
- CUDA base: 12.4 works on JetPack 6.x via minor-version compatibility
  (JetPack 6.0 = driver CUDA 12.2). Strict-alignment rebuild:
  `CUDA_BASE=12.2.2 TAG=0.1.0 ./container/build.sh`.
- The image embeds the **prebuilt web UI** when available
  (`LLAMA_USE_PREBUILT_UI=ON`): the build fetches the bundle from the
  `ggml-org/llama-ui` HF bucket and, if that fetch is unauthorized or
  unreachable, provisioning falls back **gracefully** to an API-only server.
  `OFF` in `container/Dockerfile` gives a fully deterministic zero-network
  build; air-gapped builds can instead extract the UI from a llama.cpp release
  tarball into `ui/apps/chat/dist` (priority 1 in the provisioning script).
- Gotcha: `.dockerignore` must keep `llama.cpp/scripts/` - the server's
  "Provisioning UI assets" step needs `scripts/ui-assets.cmake` and runs
  unconditionally. Symptom if dropped: `Error processing file:
  .../scripts/ui-assets.cmake`, with an unrelated object file (e.g. an mtmd
  TU) shown as ninja's last line.

### 2 - Distribute (no registry)

```bash
./scripts/distribute-image.sh 0.1.0 user@10.0.0.<AGX_IP> user@10.0.0.<NANO_IP>
```

- The jets are k3s **docker-runtime** nodes: the tar lands in Docker's store
  (`docker load`, sudo fallback). Containerd-backed nodes fall back to
  `k3s ctr images import`.
- Images must be present on every node that will run a pod (both jets).

### 3 - Deploy

```bash
./scripts/deploy.sh turing-six turing-five
```

- Labels the nodes (`jetson.role=agx|nano`), `kubectl apply -k deploy`,
  waits for rollouts. First start includes the ~20 GB model download
  (initContainer, resumable) + RPC tensor streaming to both nodes - up to
  ~20 min of startupProbe allowance; later restarts start fast (hostPath
  model reuse).
- GPU coexistence: llama uses 2 of the 4 time-sliced slots during inference
  (rpc-agx + rpc-nano); ollama keeps its 1 on turing-six. If other tenants
  hold slots and a pod stays Pending, free a slot or adjust `TS_SPLIT`.

```bash
./scripts/test.sh http://10.0.0.<AGX_IP>:30990
```

## Cluster reality (this homelab)

Node IPs are masked as role placeholders (homelab subnet 10.0.0/24); ports are unmasked.

| Fact | Value |
|---|---|
| k3s server | `turing-one` @ 10.0.0.<K3S_API>, kubeconfig `~/.kube/config`, v1.35.x |
| AGX Orin 64 GB | node **turing-six** @ 10.0.0.<AGX_IP>, 12 cores -> labeled `jetson.role=agx` by deploy.sh |
| Orin Nano 8 GB | node **turing-five** @ 10.0.0.<NANO_IP>, 6 cores -> labeled `jetson.role=nano` |
| Container runtime on jets | k3s **with Docker** - `runtimeClassName` unusable; GPU pods work via Docker's default NVIDIA runtime + `NVIDIA_DRIVER_CAPABILITIES` env (proven by the existing ollama deployment) |
| GPU advertisement | helm `nvdp` device plugin already running - **4 time-sliced slots per jetson**; never add a second device plugin (double advertisement) |
| Storage | Longhorn + local-path available; the model uses hostPath `/opt/llama-models` on turing-six (see decision log) |
| Taken NodePorts | 30800 (keycloak) and others - llama-server uses **30990** |

### What gets deployed (namespace: `llama`)

| Deployment | Node | GPU | Role |
|---|---|---|---|
| `llama-server` | turing-six | none | holds GGUF, orchestrates the RPC layer split, serves HTTP (NodePort 30990) |
| `rpc-agx` | turing-six | 1 slot | executes its layer share (~7/8 of weights at default) |
| `rpc-nano` | turing-five | 1 slot | executes the rest (~1/8) |
| `fetch-model` (init) | turing-six | none | idempotent download of `MODEL_FILE` |

### The web UI (where it lives and why)

The UI is **not a separate deployment**: with `LLAMA_USE_PREBUILT_UI=ON` the
bundle is embedded at build time inside the `llama-server` binary itself
(`scripts/ui-assets.cmake` generates `ui.cpp`/`ui.h` linked into it). There is
no UI pod and no placement choice to make: the UI is served by whoever runs
`llama-server` - the orchestrator - which `deploy/20-llama-server.yaml` pins
to the AGX (`nodeSelector: jetson.role: agx` = turing-six). "Orchestrator" and
"the AGX" are the same node in this topology.

- Reach it at `http://<any-node-ip>:30990/` (NodePort 30990 - any cluster node
  IP answers; the Service simply follows the llama-server pod).
- The AGX pin is deliberate: the AGX shares its node with `rpc-agx` (tensor
  streaming stays node-local), hosts `/opt/llama-models`, and keeps UI/API/
  template work off the Nano's 6 cores.
- If the UI bundle was not embedded (the 401 fallback path - see decision
  log), `/` serves no UI and API paths are unaffected; the flags and
  provisioning priority are documented in **Step details - 1 Build**.
- Moving the UI means moving the whole orchestrator (swap the nodeSelector).
  Possible but not recommended: the new node would also inherit the ~20 GB
  model download and the slower rpc hop.

## Memory budget (why `--ts 7,1`)

Qwen3-32B Q4_K_M is ~19.8 GB of weights; KV @8k f16 is ~2.1 GB, split by layer
share:

| Node | Weights (7,1) | + KV | + buffers + CUDA ctx | Result |
|---|---|---|---|---|
| turing-six (AGX 64 GB) | ~17.3 GB | ~1.8 GB | ~4 GB | comfortable |
| turing-five (Nano 8 GB) | ~2.5 GB | ~0.25 GB | ~2 GB | ~5 GB in use |

The same split also fits an AGX 32 GB, should one join.

## Configuration reference

All knobs: [`deploy/03-config.yaml`](deploy/03-config.yaml). Edit, then re-run
`./scripts/deploy.sh` (idempotent `kubectl apply`).

| Key | Default | Meaning |
|---|---|---|
| `MODEL_REPO` / `MODEL_FILE` | `Qwen/Qwen3-32B-GGUF` / `Qwen3-32B-Q4_K_M.gguf` | model auto-downloaded + served |
| `MODEL_URL` | `https://huggingface.co/Qwen/.../resolve/main` | swap for a mirror if WAN is slow |
| `CTX_SIZE` | `8192` | context length (KV @8k f16 ~2.1 GB, split across nodes) |
| `NGL` | `999` | offload every layer to GPU devices |
| `SPLIT_MODE` | `layer` | RPC split mode |
| `TS_SPLIT` | `7,1` | weight fractions, order = `RPC_ENDPOINTS` order (device 0 = rpc-agx) |
| `FA` | `auto` | flash attention (auto/on/off) |
| `CACHE_K` / `CACHE_V` | `f16` | `q8_0` halves KV (needs FA on) |
| `RPC_PORT` | `50052` | rpc-server listener |
| `RPC_ENDPOINTS` | `rpc-agx:50052,rpc-nano:50052` | rpc mesh + device order for `-ts` |

Preset recipes:

| Want | Change |
|---|---|
| Max speed, Nano idle | `TS_SPLIT: "1,0"`, `RPC_ENDPOINTS: "rpc-agx:50052"` |
| Max shared memory | `TS_SPLIT: "3,1"` (Nano holds ~5 GB - headless) |
| Different model | MODEL_* keys (any ungated GGUF; e.g. Llama-3.3-70B with `TS_SPLIT: "8,1"` on this AGX -> ~1 tok/s) |
| Tight Nano memory | `TS_SPLIT: "9,1"`, or `CACHE_K/V: "q8_0"` |
| Bigger context | `CTX_SIZE: "16384"` (+ `q8_0` KV recommended) |

Note: with no `-ts`, upstream llama.cpp distributes weights and KV across all
devices in proportion to each device's *free* memory (see the upstream
[rpc README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
Our fixed `7,1` is a deliberate predictability choice - free memory shifts as
ollama and other tenants come and go. On a node with several GPUs, exposure can
be pinned with `ggml-rpc-server --device CUDA0`.

## Thinking mode

Qwen3 is a hybrid thinking model - default output starts with a thinking
block. For chat speed, disable it. Either works (what `scripts/test.sh` does):

- Per request: `{ "messages": [...], "chat_template_kwargs": {"enable_thinking": false} }`
- Prompt-level: `/no_think` in the system prompt.

## API usage

```bash
URL=http://10.0.0.<AGX_IP>:30990

curl -s $URL/health
curl -s $URL/props | python3 -m json.tool | head -20

# non-streaming, thinking off
curl -s $URL/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [
    {"role": "system", "content": "/no_think"},
    {"role": "user", "content": "Hello, what are you running on?"}
  ],
  "max_tokens": 128,
  "chat_template_kwargs": {"enable_thinking": false}
}'
```

Streaming: add `"stream": true` (SSE). OpenAI-compatible paths
(`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`) work as usual.

## RPC security

llama.cpp RPC has **no authentication**. The rpc Services stay ClusterIP-only
inside the cluster, and `deploy/30-networkpolicy.yaml` restricts ingress to the
llama-server pod (k3s's embedded kube-router enforces NetworkPolicy unless the
cluster runs with `--disable-network-policy`). Never expose `rpc-agx` /
`rpc-nano` via NodePort.

Upstream reference for the RPC backend - including the "proof-of-concept, never
expose it on an open network" warning that motivates the NetworkPolicy:
[llama.cpp tools/rpc/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md).

## Speed expectations

| Config | Approx decode tok/s (1 user) |
|---|---|
| Qwen3-32B Q4, AGX-only (`1,0`) | TBA |
| Qwen3-32B Q4, `7,1` split | TBA |
| 70B-class Q4, `8,1` split | TBA |

The Nano has ~1/8 of the AGX's GPU: including it costs a little decode speed
but frees ~15 GB of AGX memory (useful at bigger models/contexts) - the
resource-sharing trade-off this deployment encodes.

## Troubleshooting

- **Pod Pending, "Insufficient nvidia.com/gpu"** - all 4 time-sliced slots
  held on that node: `kubectl describe node turing-six | grep -A20 "Allocated resources"`.
- **CUDA init failure in rpc pods** - CUDA 12.4 image vs JetPack 6.0's 12.2
  driver: rebuild `CUDA_BASE=12.2.2` (minor-version compatibility usually
  covers this).
- **Pod Pending, "image not found"** - re-run step 2 on both nodes (images
  land in **Docker's** store on the jets, not containerd).
- **llama-server not Ready > 20 min** - watch the download:
  `kubectl -n llama logs deploy/llama-server -c fetch-model -f`. Later
  restarts reuse hostPath `/opt/llama-models`.
- **rpc "connection refused"** - namespaces/netpol: both rpc pods and
  llama-server must be in `llama`; check `kubectl -n llama get netpol,pods -o wide`.
- **Nano OOMKilled** - `TS_SPLIT: "9,1"`, or `CACHE_K/V: "q8_0"`.
- **Build fails at "Provisioning UI assets" / `Error processing file:
  scripts/ui-assets.cmake`** - build context dropped `llama.cpp/scripts/`;
  keep it out of `.dockerignore`.
- **Slow first token** - the warm-up passes through all RPC layers once;
  subsequent requests are normal.
- **RPC debugging** - `GGML_RPC_DEBUG=1` (1 = events, 2 = per-command trace,
  3 = timings) on either side, paired with `-lv 5` on the llama-server side so
  records are not dropped:
  `kubectl -n llama set env deploy/rpc-agx deploy/rpc-nano GGML_RPC_DEBUG=2`.
- **Slow llama-server restart** - the rpc pods keep a **local tensor cache**
  (`ggml-rpc-server -c`, `LLAMA_CACHE=/var/cache/llama-rpc`, backed by hostPath
  `/opt/llama-rpc-cache`): the first load streams tensors over the network,
  later restarts read them from local disk. If a node is disk-constrained,
  remove `-c` and the cache volume from `deploy/10-rpc-servers.yaml` (or
  `rm -rf /opt/llama-rpc-cache` on that node).

## Decision log

- **RPC, not MPI.** llama.cpp removed its MPI backend in May 2024 (commit
  `d359f3092`); the current checkout has no `GGML_MPI`. The RPC backend is the
  maintained multi-node mechanism with the same layer-split resource sharing.
  Decided 2026-11-21.
- **API-only image (current reality).** `LLAMA_USE_PREBUILT_UI=ON` was flipped
  on 2026-11-23, but the `ggml-org/llama-ui` bucket answers 401 from this build
  host, so provisioning falls back to an empty embedded UI. For a real browser
  UI: provide an HF token with access to the bucket, or vendor the prebuilt UI
  from a llama.cpp GitHub release into `llama.cpp/ui/apps/chat/dist`
  (highest provisioning priority). `LLAMA_USE_PREBUILT_UI=OFF` skips the fetch.
- **hostPath, not Longhorn** for the model: the llama-server pod is pinned to
  the AGX node, and a Longhorn replica would risk landing on the Nano's
  constrained storage. Revisit if the pod unpins.

## Cleanup

```bash
./scripts/undeploy.sh                              # cluster side
ssh <user>@10.0.0.<AGX_IP> 'rm -rf /opt/llama-models'     # model on the AGX (optional)
```
