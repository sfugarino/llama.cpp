#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Configure the NVIDIA container runtime for k3s on a Jetson.
# NOT needed for turing-five/turing-six (GPU already schedulable there via
# the cluster's nvdp device plugin). Keep for onboarding a FRESH jetson node
# that has k3s installed but no NVIDIA runtime yet.
#
# Run from the admin/x86 host:  ./scripts/cluster-nvidia-setup.sh user@agx user@nano
# Idempotent: re-run safely.
# ---------------------------------------------------------------------------
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <user@agx-host> [user@nano-host ...]" >&2; exit 1; }

for NODE in "$@"; do
    echo "== $NODE: NVIDIA container runtime for k3s =="
    ssh "$NODE" 'bash -s' <<'REMOTE'
set -euo pipefail

echo "-- 1/4 JetPack present?"
if ! nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi failed - JetPack 6 driver not installed" >&2
    exit 1
fi

echo "-- 2/4 nvidia-container-toolkit present?"
if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit \
        || { echo "apt install failed - install manually, see nvidia docs" >&2; exit 1; }
fi

K3S_DIR=/var/lib/rancher/k3s/agent/etc/containerd
CONF="$K3S_DIR/config.toml"
TMPL="$K3S_DIR/config.toml.tmpl"

echo "-- 3/4 containerd template with nvidia runtime"
sudo mkdir -p "$K3S_DIR"
if [ ! -f "$TMPL" ]; then
    # k3s renders its config from this template; seed it with the generated one
    sudo cp "$CONF" "$TMPL"
fi
if ! sudo grep -q 'runtimes.nvidia' "$TMPL"; then
    sudo tee -a "$TMPL" >/dev/null <<'BLOCK'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_engine = ""
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
BLOCK
fi

echo "-- 4/4 restarting k3s"
if systemctl is-active --quiet k3s; then
    sudo systemctl restart k3s
elif systemctl is-active --quiet k3s-agent; then
    sudo systemctl restart k3s-agent
else
    echo "k3s service not found on this node" >&2
    exit 1
fi
sleep 5
systemctl is-active k3s >/dev/null || systemctl is-active k3s-agent >/dev/null
echo "-- ok"
REMOTE
done

echo
echo "All nodes configured."
echo "Check GPU visibility after deploy (device plugin comes with apply):"
echo "  kubectl get nodes -o json | python3 -c \"import json,sys; [print(n['metadata']['name'], n['status']['allocatable'].get('nvidia.com/gpu')) for n in json.load(sys.stdin)['items']]\""
