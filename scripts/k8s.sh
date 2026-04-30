#!/bin/sh
set -eu

GREEN=$(tput setaf 2 2>/dev/null || printf '')
YELLOW=$(tput setaf 3 2>/dev/null || printf '')
MAGENTA=$(tput setaf 5 2>/dev/null || printf '')
CYAN=$(tput setaf 6 2>/dev/null || printf '')
RESET=$(tput sgr0 2>/dev/null || printf '')

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.34}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.3}"
SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd)

info() {
  printf '%s%s%s\n' "$CYAN" "$1" "$RESET"
}

success() {
  printf '%s%s%s\n' "$GREEN" "$1" "$RESET"
}

warn() {
  printf '%s%s%s\n' "$YELLOW" "$1" "$RESET"
}

error() {
  printf '%sERROR: %s%s\n' "$MAGENTA" "$1" "$RESET" >&2
}

usage() {
  cat <<EOF
Usage:
  sh scripts/k8s.sh master
  sh scripts/k8s.sh worker '<kubeadm join ...>'

Prerequisites:
  - Run inside the Incus VM for this node
  - Ubuntu-family OS with apt-get
  - VM subnets are routed over the physical hosts' Tailscale connections
  - Run with sudo privileges

Environment overrides:
  KUBERNETES_VERSION=${KUBERNETES_VERSION}
  CILIUM_VERSION=${CILIUM_VERSION}
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "$1 is required"
    exit 1
  fi
}

check_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return
  fi

  need_cmd sudo
  if ! sudo -v; then
    error "sudo privileges are required"
    exit 1
  fi
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo --preserve-env=KUBECONFIG "$@"
  fi
}

check_os() {
  if [ ! -r /etc/os-release ]; then
    error "/etc/os-release is required to detect the OS"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id=${ID:-}
  os_like=${ID_LIKE:-}
  os_name=${PRETTY_NAME:-unknown}

  case " $os_id $os_like " in
    *" ubuntu "*)
      success "OS detected: $os_name"
      ;;
    *)
      error "unsupported OS: $os_name. Ubuntu-family distributions are expected."
      exit 1
      ;;
  esac

  need_cmd apt-get
}

detect_node_ip() {
  node_ip=${NODE_IP:-}
  if [ -z "$node_ip" ]; then
    node_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | sed -n '1p')
  fi

  if [ -z "$node_ip" ]; then
    error "could not detect this VM's IPv4 address. Set NODE_IP explicitly."
    exit 1
  fi

  success "Node IPv4 detected: $node_ip"
}

prepare_node() {
  info "Preparing Kubernetes node packages and kernel settings..."

  run_as_root swapoff -a
  if [ -f /etc/fstab ]; then
    run_as_root sed -i.bak '/\sswap\s/d; /\sswap$/d' /etc/fstab
  fi

  run_as_root mkdir -p /etc/modules-load.d /etc/sysctl.d /etc/containerd /etc/apt/keyrings
  printf '%s\n%s\n' overlay br_netfilter | run_as_root tee /etc/modules-load.d/k8s.conf >/dev/null
  run_as_root modprobe overlay
  run_as_root modprobe br_netfilter

  cat <<'EOF' | run_as_root tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  run_as_root sysctl --system >/dev/null

  run_as_root apt-get update
  run_as_root apt-get install -y apt-transport-https ca-certificates curl gpg containerd

  run_as_root sh -c 'containerd config default > /etc/containerd/config.toml'
  run_as_root sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  run_as_root systemctl restart containerd
  run_as_root systemctl enable containerd

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
    | run_as_root gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
    | run_as_root tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

  run_as_root apt-get update
  run_as_root apt-get install -y kubelet kubeadm kubectl
  run_as_root apt-mark hold kubelet kubeadm kubectl
  printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$node_ip" | run_as_root tee /etc/default/kubelet >/dev/null
  run_as_root systemctl enable kubelet

  success "Node preparation complete."
}

install_cilium_cli() {
  if command -v cilium >/dev/null 2>&1; then
    success "Cilium CLI is already installed."
    return
  fi

  info "Installing Cilium CLI..."
  cilium_cli_version=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  cli_arch=amd64
  if [ "$(uname -m)" = "aarch64" ]; then
    cli_arch=arm64
  fi

  tmp_dir=$(mktemp -d)
  (
    cd "$tmp_dir"
    curl -L --fail --remote-name-all \
      "https://github.com/cilium/cilium-cli/releases/download/${cilium_cli_version}/cilium-linux-${cli_arch}.tar.gz" \
      "https://github.com/cilium/cilium-cli/releases/download/${cilium_cli_version}/cilium-linux-${cli_arch}.tar.gz.sha256sum"
    sha256sum --check "cilium-linux-${cli_arch}.tar.gz.sha256sum"
    run_as_root tar xzf "cilium-linux-${cli_arch}.tar.gz" -C /usr/local/bin
  )
  rm -rf "$tmp_dir"
  success "Cilium CLI installed."
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    success "Helm is already installed."
    return
  fi

  info "Installing Helm..."
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  run_as_root /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh
  success "Helm installed."
}

install_k9s() {
  if command -v k9s >/dev/null 2>&1; then
    success "k9s is already installed."
    return
  fi

  info "Installing k9s on the master node..."
  dpkg_arch=$(dpkg --print-architecture)
  case "$dpkg_arch" in
    amd64) k9s_arch=amd64 ;;
    arm64) k9s_arch=arm64 ;;
    *)
      warn "Skipping k9s install: unsupported architecture $dpkg_arch"
      return
      ;;
  esac

  curl -fsSL -o "/tmp/k9s_linux_${k9s_arch}.deb" "https://github.com/derailed/k9s/releases/latest/download/k9s_linux_${k9s_arch}.deb"
  run_as_root apt-get install -y "/tmp/k9s_linux_${k9s_arch}.deb"
  rm -f "/tmp/k9s_linux_${k9s_arch}.deb"
  success "k9s installed."
}

init_master() {
  check_os
  check_sudo
  detect_node_ip
  prepare_node

  info "Initializing Kubernetes control plane on VM IP ${node_ip}..."
  run_as_root kubeadm init \
    --skip-phases=addon/kube-proxy \
    --apiserver-advertise-address="$node_ip" \
    --control-plane-endpoint="$node_ip"

  info "Configuring kubectl on the master node..."
  run_as_root mkdir -p /root/.kube
  run_as_root cp -f /etc/kubernetes/admin.conf /root/.kube/config
  run_as_root chown root:root /root/.kube/config
  export KUBECONFIG=/etc/kubernetes/admin.conf
  success "kubectl configured."

  info "Allowing workloads on the control-plane node..."
  run_as_root kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  success "Control-plane node is schedulable."

  install_cilium_cli

  info "Installing Cilium CNI with Ingress Controller..."
  run_as_root cilium install --version "$CILIUM_VERSION" \
    --set ingressController.enabled=true \
    --set ingressController.loadbalancerMode=shared
  success "Cilium CNI installed."

  info "Waiting for Cilium to be ready..."
  run_as_root cilium status --wait

  info "Enabling Hubble..."
  run_as_root cilium hubble enable --ui

  install_helm

  info "Installing Argo CD..."
  run_as_root kubectl create namespace argocd --dry-run=client -o yaml | run_as_root kubectl apply -f -
  run_as_root kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  info "Configuring Argo CD insecure mode (TLS termination at reverse proxy)..."
  run_as_root kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
  run_as_root kubectl rollout restart deployment argocd-server -n argocd

  info "Waiting for Argo CD to be ready..."
  run_as_root kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-applicationset-controller -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-dex-server -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-notifications-controller -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-redis -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=600s
  run_as_root kubectl rollout status deployment/argocd-server -n argocd --timeout=600s
  success "Argo CD installed."

  install_k9s

  info "Checking cluster health..."
  run_as_root kubectl get nodes -o wide
  run_as_root kubectl get pods -A

  info "Applying Argo CD root application..."
  run_as_root kubectl apply -f "$REPO_ROOT/manifests/apps/root.yaml"
  success "Argo CD root application applied."

  info "Generating worker join command..."
  join_cmd=$(run_as_root kubeadm token create --print-join-command)

  echo ""
  success "========================================"
  success "Master setup complete!"
  success "========================================"
  echo ""
  warn "Run the matching command from each worker's physical host after copying this repo into the worker VM:"
  printf "  sudo incus exec k8s-worker1 -- sh /root/kotarnetes/scripts/k8s.sh worker '%s'\n" "$join_cmd"
  printf "  sudo incus exec k8s-worker2 -- sh /root/kotarnetes/scripts/k8s.sh worker '%s'\n" "$join_cmd"
  echo ""
  warn "If you are already inside a worker VM, run:"
  printf "  cd /root/kotarnetes && sh scripts/k8s.sh worker '%s'\n" "$join_cmd"
  echo ""
  warn "Argo CD:"
  echo "  kubectl --kubeconfig /etc/kubernetes/admin.conf port-forward svc/argocd-server -n argocd 8080:80"
  echo "  URL: http://localhost:8080"
  echo "  Username: admin"
  echo "  Password: kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  echo ""
  warn "Hubble UI:"
  echo "  kubectl --kubeconfig /etc/kubernetes/admin.conf port-forward -n kube-system svc/hubble-ui 12000:80"
  echo "  URL: http://localhost:12000"
  echo ""
}

join_worker() {
  if [ "$#" -eq 0 ]; then
    error "worker requires a kubeadm join command"
    usage
    exit 1
  fi

  join_cmd=$*

  check_os
  check_sudo
  detect_node_ip
  prepare_node

  info "Joining this worker node to the cluster..."
  run_as_root $join_cmd
  success "Worker joined the cluster."
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

role=$1
shift

case "$role" in
  master)
    init_master
    ;;
  worker)
    join_worker "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    error "unknown role: $role"
    usage
    exit 1
    ;;
esac
