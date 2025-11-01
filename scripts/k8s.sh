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
incus exec k8s-master -- cilium install --version 1.18.3

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

# クラスタの状態を確認
echo "${CYAN}Checking cluster status...${RESET}"
incus exec k8s-master -- kubectl get nodes

echo "${CYAN}Waiting for Cilium to be ready...${RESET}"
incus exec k8s-master -- cilium status --wait

echo "${GREEN}Setup complete!${RESET}"
