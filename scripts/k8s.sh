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
incus exec k8s-master -- bash -c "mkdir -p $HOME/.kube && sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config"
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

echo "${CYAN}Installing Cilium CNI...${RESET}"
incus exec k8s-master -- bash -c 'export KUBECONFIG=$HOME/.kube/config && cilium install --version 1.18.3'

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

# クラスタの状態を確認
echo "${CYAN}Checking cluster health...${RESET}"
incus exec k8s-master -- kubectl get nodes -o wide
incus exec k8s-master -- kubectl get pods -A -o wide
incus exec k8s-master -- kubectl -n kube-system get pods

echo "${CYAN}Checking worker1 cluster status...${RESET}"
incus exec k8s-worker1 -- kubectl get nodes -o wide
incus exec k8s-worker1 -- kubectl get pods -A -o wide
incus exec k8s-worker1 -- kubectl -n kube-system get pods

echo "${CYAN}Checking worker2 cluster status...${RESET}"
incus exec k8s-worker2 -- kubectl get nodes -o wide
incus exec k8s-worker2 -- kubectl get pods -A -o wide
incus exec k8s-worker2 -- kubectl -n kube-system get pods

echo "${CYAN}Checking Cilium status...${RESET}"
incus exec k8s-master -- cilium status
incus exec k8s-master -- cilium connectivity test

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
incus exec k8s-master -- kubectl wait --namespace argocd --for=condition=ready pod --all
incus exec k8s-master -- kubectl port-forward svc/argocd-server -n argocd 8080:443

ARGOCD_PASSWORD=$(incus exec k8s-master -- kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)

echo "${CYAN}Argo CD admin password: $ARGOCD_PASSWORD${RESET}"

echo "${YELLOW}Accessing Argo CD...${RESET}"
echo "${YELLOW}http://127.0.0.1:8080${RESET}"
echo "${YELLOW}Username: admin${RESET}"
echo "${YELLOW}Password: $ARGOCD_PASSWORD${RESET}"

# Metrics Serverのインストール
echo "${CYAN}Installing Metrics Server...${RESET}"
incus exec k8s-master -- bash -c '
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
'
echo "${GREEN}Metrics Server installed!${RESET}"

# Kubernetes Dashboardのインストール
echo "${CYAN}Installing Kubernetes Dashboard...${RESET}"
incus exec k8s-master -- bash -c '
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard
'
echo "${GREEN}Kubernetes Dashboard installed!${RESET}"

# k9sのインストール
echo "${CYAN}Installing k9s...${RESET}"
incus exec k8s-master -- bash -c '
wget https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
apt install ./k9s_linux_amd64.deb
rm k9s_linux_amd64.deb
'
echo "${GREEN}k9s installed!${RESET}"

echo "${GREEN}Setup complete!${RESET}"
