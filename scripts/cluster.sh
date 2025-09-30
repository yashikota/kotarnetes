#!/bin/bash
set -e

echo "Waiting for VMs to start..."
echo ""

# VMが起動してエージェントが利用可能になるまで待つ
wait_for_vm() {
  local vm_name=$1
  echo "Waiting for $vm_name..."

  for i in {1..60}; do
    if incus exec $vm_name -- echo "ready" >/dev/null 2>&1; then
      echo "$vm_name is ready!"
      return 0
    fi
    sleep 5
  done

  echo "ERROR: $vm_name did not start in time"
  return 1
}

wait_for_vm k8s-master
wait_for_vm k8s-worker1
wait_for_vm k8s-worker2

echo ""
echo "Waiting for cloud-init to complete..."
incus exec k8s-master -- cloud-init status --wait
incus exec k8s-worker1 -- cloud-init status --wait
incus exec k8s-worker2 -- cloud-init status --wait

echo ""
echo "============================================"
echo "Initializing Kubernetes cluster..."
echo "============================================"
echo ""

# マスターノードでクラスタを初期化
echo "Initializing master node..."
incus exec k8s-master -- bash -c "kubeadm init --skip-phases=addon/kube-proxy"

# kubectl設定
echo "Configuring kubectl..."
incus exec k8s-master -- bash -c "mkdir -p /root/.kube && cp -i /etc/kubernetes/admin.conf /root/.kube/config && chown root:root /root/.kube/config"

# Cilium CLIをインストール
# Reference: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default
echo "Installing Cilium CLI..."
incus exec k8s-master -- bash -c '
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
'

echo "Installing Cilium CNI..."
incus exec k8s-master -- cilium install --version 1.16.5

# joinコマンドを取得
echo ""
echo "============================================"
echo "Generating join command..."
echo "============================================"
echo ""
JOIN_CMD=$(incus exec k8s-master -- kubeadm token create --print-join-command)
echo "Join command: $JOIN_CMD"

# ワーカーノードを参加させる
echo ""
echo "============================================"
echo "Joining worker nodes to cluster..."
echo "============================================"
echo ""

echo "Joining k8s-worker1..."
incus exec k8s-worker1 -- bash -c "$JOIN_CMD"

echo "Joining k8s-worker2..."
incus exec k8s-worker2 -- bash -c "$JOIN_CMD"

echo ""
echo "============================================"
echo "Cluster setup complete!"
echo "============================================"
echo ""

# クラスタの状態を確認
echo "Checking cluster status..."
incus exec k8s-master -- kubectl get nodes

echo ""
echo "Waiting for Cilium to be ready..."
incus exec k8s-master -- cilium status --wait

echo ""
echo "To access the cluster, run:"
echo "  incus exec k8s-master -- bash"
echo "  kubectl get nodes"
echo "  cilium status"
echo ""
