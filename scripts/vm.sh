#!/bin/sh
set -eu

GREEN=$(tput setaf 2 2>/dev/null || printf '')
YELLOW=$(tput setaf 3 2>/dev/null || printf '')
MAGENTA=$(tput setaf 5 2>/dev/null || printf '')
CYAN=$(tput setaf 6 2>/dev/null || printf '')
RESET=$(tput sgr0 2>/dev/null || printf '')
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
  cat <<'EOF'
Usage:
  sh scripts/vm.sh master
  sh scripts/vm.sh worker1
  sh scripts/vm.sh worker2

Run this on each physical host. It creates one Incus VM on the current host:
  master  -> k8s-master
  worker1 -> k8s-worker1
  worker2 -> k8s-worker2

The physical host must already be joined to Tailscale. This script assigns a
role-specific Incus subnet and prints the Tailscale subnet route to advertise.
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "$1 is required"
    exit 1
  fi
}

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

vm_name_for_role() {
  case "$1" in
    master) printf '%s\n' k8s-master ;;
    worker1) printf '%s\n' k8s-worker1 ;;
    worker2) printf '%s\n' k8s-worker2 ;;
    *)
      error "unknown role: $1"
      usage
      exit 1
      ;;
  esac
}

vm_resources_for_role() {
  case "$1" in
    master)  printf '%s %s\n' 2 8GiB ;;
    worker*) printf '%s %s\n' 11 11GiB ;;
  esac
}

subnet_for_role() {
  case "$1" in
    master) printf '%s\n' 10.210.1.1/24 ;;
    worker1) printf '%s\n' 10.210.2.1/24 ;;
    worker2) printf '%s\n' 10.210.3.1/24 ;;
    *)
      error "unknown role: $1"
      usage
      exit 1
      ;;
  esac
}

route_for_subnet() {
  printf '%s\n' "$1" | awk -F'[./]' '{ printf "%s.%s.%s.0/%s\n", $1, $2, $3, $5 }'
}

ensure_incus() {
  need_cmd apt
  current_user=${SUDO_USER:-${USER:-root}}

  if ! command -v incus >/dev/null 2>&1; then
    info "Installing Incus..."
    run_sudo apt update
    run_sudo apt install -y incus qemu-system
  fi

  if [ "$current_user" != root ] && ! id -nG "$current_user" | tr ' ' '\n' | grep -qx incus-admin; then
    warn "Adding $current_user to incus-admin. You may need to re-login or run 'newgrp incus-admin'."
    run_sudo adduser "$current_user" incus-admin
  fi
}

check_tailscale_host() {
  need_cmd tailscale

  if ! tailscale status >/dev/null 2>&1; then
    error "the physical host must be joined to Tailscale before creating the VM"
    exit 1
  fi

  success "Host Tailscale is online."
}

configure_host_routing() {
  host_route=$1

  info "Enabling IPv4 forwarding on the physical host..."
  run_sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
  printf '%s\n' 'net.ipv4.ip_forward = 1' | run_sudo tee /etc/sysctl.d/99-kotarnetes-routing.conf >/dev/null

  if command -v iptables >/dev/null 2>&1; then
    # Keep VM-to-VM traffic routed over Tailscale without SNAT, while leaving
    # Incus NAT available for regular internet access from the VM.
    run_sudo iptables -t nat -C POSTROUTING -s "$host_route" -d 10.210.0.0/16 -j RETURN 2>/dev/null \
      || run_sudo iptables -t nat -I POSTROUTING 1 -s "$host_route" -d 10.210.0.0/16 -j RETURN
    run_sudo iptables -C FORWARD -s "$host_route" -d 10.210.0.0/16 -j ACCEPT 2>/dev/null \
      || run_sudo iptables -I FORWARD 1 -s "$host_route" -d 10.210.0.0/16 -j ACCEPT
    run_sudo iptables -C FORWARD -s 10.210.0.0/16 -d "$host_route" -j ACCEPT 2>/dev/null \
      || run_sudo iptables -I FORWARD 1 -s 10.210.0.0/16 -d "$host_route" -j ACCEPT
  else
    warn "iptables was not found. Ensure host firewall rules allow routed VM subnet traffic."
  fi

  success "Host IPv4 forwarding is enabled."
}

ensure_incus_initialized() {
  if run_sudo incus network show incusbr0 >/dev/null 2>&1; then
    success "Incus is already initialized."
    return
  fi

  info "Initializing Incus..."
  run_sudo incus admin init --preseed < "$REPO_ROOT/scripts/incus-init.yaml"
}

configure_incus_network() {
  subnet=$1

  info "Configuring incusbr0 as $subnet..."
  run_sudo incus network set incusbr0 ipv4.address "$subnet"
  run_sudo incus network set incusbr0 ipv4.nat true
  run_sudo incus network set incusbr0 ipv6.address none
  success "incusbr0 configured."
}

launch_vm() {
  vm_name=$1
  vm_cpu=$2
  vm_memory=$3

  if run_sudo incus info "$vm_name" >/dev/null 2>&1; then
    warn "$vm_name already exists."
    run_sudo incus list "$vm_name"
    return
  fi

  info "Launching $vm_name (cpu=$vm_cpu, memory=$vm_memory)..."
  run_sudo incus launch images:ubuntu/24.04/cloud "$vm_name" --vm \
    --config=user.user-data="$(cat "$REPO_ROOT/scripts/cloud-init.yaml")" \
    --config=limits.cpu="$vm_cpu" \
    --config=limits.memory="$vm_memory"
  success "$vm_name launched."
}

wait_for_vm() {
  vm_name=$1
  info "Waiting for $vm_name agent..."

  max_attempts=36
  i=1
  while [ "$i" -le "$max_attempts" ]; do
    if run_sudo incus exec "$vm_name" -- true >/dev/null 2>&1; then
      success "$vm_name agent is ready."
      return
    fi
    warn "Attempt $i/$max_attempts... waiting 5s"
    sleep 5
    i=$((i + 1))
  done

  error "$vm_name did not become ready in time"
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

case "$1" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

vm_name=$(vm_name_for_role "$1")
incus_subnet=$(subnet_for_role "$1")
tailscale_route=$(route_for_subnet "$incus_subnet")
vm_res=$(vm_resources_for_role "$1")
vm_cpu=$(echo "$vm_res" | awk '{print $1}')
vm_memory=$(echo "$vm_res" | awk '{print $2}')

ensure_incus
check_tailscale_host
configure_host_routing "$tailscale_route"
ensure_incus_initialized
configure_incus_network "$incus_subnet"
launch_vm "$vm_name" "$vm_cpu" "$vm_memory"
wait_for_vm "$vm_name"

info "Waiting for cloud-init in $vm_name..."
run_sudo incus exec "$vm_name" -- cloud-init status --wait
success "$vm_name is ready."

echo ""
warn "Next steps:"
echo "  sudo tailscale set --advertise-routes=$tailscale_route --snat-subnet-routes=false"
echo "  # Approve the route in the Tailscale admin console if required."
echo "  sudo incus exec $vm_name -- rm -rf /root/kotarnetes"
echo "  sudo incus exec $vm_name -- mkdir -p /root/kotarnetes"
echo "  sudo incus file push -r ./ $vm_name/root/kotarnetes/"
if [ "$1" = "master" ]; then
  echo "  sudo incus exec $vm_name -- sh /root/kotarnetes/scripts/k8s.sh master"
else
  echo "  sudo incus exec $vm_name -- sh /root/kotarnetes/scripts/k8s.sh worker '<kubeadm join ...>'"
fi
