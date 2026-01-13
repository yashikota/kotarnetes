#!/bin/bash
set -e

# Color variables
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

echo "${CYAN}Waiting for VMs to start...${RESET}"

# VMが起動してエージェントが利用可能になるまで待つ
wait_for_vm() {
  local vm_name=$1
  echo "${CYAN}Waiting for $vm_name...${RESET}"

  local max_attempts=12  # 1分間待機 (12 * 5秒)
  for i in $(seq 1 $max_attempts); do
    if incus exec $vm_name -- echo "ready" >/dev/null 2>&1; then
      echo "${GREEN}$vm_name is ready!${RESET}"
      return 0
    fi
    echo "${YELLOW}Attempt $i/$max_attempts... (waiting 5s)${RESET}"
    sleep 5
  done

  echo "${MAGENTA}ERROR: $vm_name did not start in time${RESET}"
  return 1
}

wait_for_vm k8s-master
wait_for_vm k8s-worker1
wait_for_vm k8s-worker2

echo "${CYAN}Waiting for cloud-init to complete...${RESET}"
incus exec k8s-master -- cloud-init status --wait
incus exec k8s-worker1 -- cloud-init status --wait
incus exec k8s-worker2 -- cloud-init status --wait

echo "${GREEN}Initializing Kubernetes cluster...${RESET}"

# マスターノードでクラスタを初期化
echo "${CYAN}Initializing master node...${RESET}"
incus exec k8s-master -- bash -c "kubeadm init --skip-phases=addon/kube-proxy"

# kubectl設定
echo "${CYAN}Configuring kubectl...${RESET}"
incus exec k8s-master -- bash -c "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chown root:root /root/.kube/config"
echo "${GREEN}kubectl configured!${RESET}"

# Cilium CLIをインストール
# Reference: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default
echo "${CYAN}Installing Cilium CLI...${RESET}"
incus exec k8s-master -- bash -c '
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
tar xvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
'

echo "${CYAN}Installing Cilium CNI with Ingress Controller...${RESET}"
incus exec k8s-master -- cilium install --version 1.18.3 \
  --set ingressController.enabled=true \
  --set ingressController.loadbalancerMode=shared

echo "${GREEN}Cilium CNI installed!${RESET}"

# joinコマンドを取得
echo "${CYAN}Generating join command...${RESET}"
JOIN_CMD=$(incus exec k8s-master -- kubeadm token create --print-join-command)
echo "${YELLOW}Join command: $JOIN_CMD${RESET}"

# ワーカーノードを参加させる
echo "${CYAN}Joining worker nodes to cluster...${RESET}"

echo "${CYAN}Joining k8s-worker1...${RESET}"
incus exec k8s-worker1 -- bash -c "$JOIN_CMD"

echo "${CYAN}Joining k8s-worker2...${RESET}"
incus exec k8s-worker2 -- bash -c "$JOIN_CMD"

echo "${GREEN}Cluster setup complete!${RESET}"

# ciliumが準備できるまで待つ
echo "${CYAN}Waiting for Cilium to be ready...${RESET}"
incus exec k8s-master -- cilium status --wait

# Hubbleの有効化
echo "${CYAN}Enabling Hubble...${RESET}"
incus exec k8s-master -- cilium hubble enable --ui

# Helmのインストール
echo "${CYAN}Installing Helm...${RESET}"
incus exec k8s-master -- bash -c '
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh
'
echo "${GREEN}Helm installed!${RESET}"

# Argo CDのインストール
echo "${CYAN}Installing Argo CD...${RESET}"
incus exec k8s-master -- bash -c '
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
'

echo "${CYAN}Waiting for Argo CD to be ready...${RESET}"
incus exec k8s-master -- kubectl wait --namespace argocd --for=condition=ready pod --all --timeout=300s
echo "${GREEN}Argo CD installed!${RESET}"

# kubectlをホストにインストール
echo "${CYAN}Installing kubectl on host...${RESET}"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
echo "${GREEN}kubectl installed on host!${RESET}"

# kubeconfigをホストにコピー
echo "${CYAN}Copying kubeconfig to host...${RESET}"
mkdir -p ~/.kube
incus exec k8s-master -- cat /root/.kube/config > ~/.kube/config
echo "${GREEN}kubeconfig copied to ~/.kube/config${RESET}"

# k9sをホストにインストール
echo "${CYAN}Installing k9s on host...${RESET}"
curl -Lo /tmp/k9s_linux_amd64.deb https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
sudo apt install -y /tmp/k9s_linux_amd64.deb
rm /tmp/k9s_linux_amd64.deb
echo "${GREEN}k9s installed on host!${RESET}"

# クラスタの状態を確認
echo "${CYAN}Checking cluster health...${RESET}"
kubectl get nodes -o wide
kubectl get pods -A

# Argo CD root applicationを適用
echo "${CYAN}Applying Argo CD root application...${RESET}"
kubectl apply -f manifests/apps/root.yaml
echo "${GREEN}Argo CD root application applied!${RESET}"

echo ""
echo "${GREEN}========================================${RESET}"
echo "${GREEN}Setup complete!${RESET}"
echo "${GREEN}========================================${RESET}"
echo ""
echo "${YELLOW}Argo CD:${RESET}"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  URL: https://localhost:8080"
echo "  Username: admin"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "${YELLOW}Hubble UI:${RESET}"
echo "  kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
echo "  URL: http://localhost:12000"
echo ""
