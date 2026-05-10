#!/bin/sh
set -eu

GREEN=$(tput setaf 2 2>/dev/null || printf '')
YELLOW=$(tput setaf 3 2>/dev/null || printf '')
MAGENTA=$(tput setaf 5 2>/dev/null || printf '')
CYAN=$(tput setaf 6 2>/dev/null || printf '')
RESET=$(tput sgr0 2>/dev/null || printf '')

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
  sh scripts/mackerel.sh <MACKEREL_APIKEY> [ROLE]

Install mackerel-agent and check plugins on a physical host for system-level
health monitoring (CPU, memory, disk, network, processes).

This script is intended to run directly on each physical host, NOT inside
Incus VMs. It monitors the bare-metal machine that hosts the VMs.

Arguments:
  MACKEREL_APIKEY  Mackerel API key for the organization
  ROLE             Optional role name (e.g. master, worker1, worker2).
                   Used to set the service/role in Mackerel.

Examples:
  # On the master physical host
  sh scripts/mackerel.sh 'YOUR_API_KEY' master

  # On worker1 physical host
  sh scripts/mackerel.sh 'YOUR_API_KEY' worker1
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

install_mackerel_agent() {
  apikey=$1

  if command -v mackerel-agent >/dev/null 2>&1; then
    warn "mackerel-agent is already installed."
    return
  fi

  need_cmd apt-get

  info "Adding Mackerel apt repository..."
  run_sudo sh -c 'wget -q -O - https://mackerel.io/file/script/setup-all-apt-v2.sh | sh'

  info "Installing mackerel-agent..."
  run_sudo apt-get install -y mackerel-agent

  info "Initializing mackerel-agent..."
  run_sudo mackerel-agent init -apikey "$apikey"

  success "mackerel-agent installed."
}

install_check_plugins() {
  if dpkg -l mackerel-check-plugins >/dev/null 2>&1; then
    warn "mackerel-check-plugins is already installed."
    return
  fi

  info "Installing mackerel-check-plugins..."
  run_sudo apt-get install -y mackerel-check-plugins

  success "mackerel-check-plugins installed."
}

configure_agent() {
  role=$1
  conf="/etc/mackerel-agent/mackerel-agent.conf"

  if [ ! -f "$conf" ]; then
    error "$conf not found. Is mackerel-agent installed?"
    exit 1
  fi

  info "Configuring mackerel-agent..."

  if grep -q '# --- kotarnetes ---' "$conf"; then
    warn "kotarnetes config already exists in $conf. Skipping."
    return
  fi

  run_sudo tee -a "$conf" >/dev/null <<EOF

# --- kotarnetes ---
EOF

  # service/role
  if [ -n "$role" ]; then
    run_sudo tee -a "$conf" >/dev/null <<EOF
roles = ["kotarnetes:$role"]
EOF
  fi

  run_sudo tee -a "$conf" >/dev/null <<'EOF'

# Disk usage (warning: 85%, critical: 95%)
[plugin.checks.disk]
command = ["check-disk", "-w", "85", "-c", "95"]

# Incus process monitoring
[plugin.checks.incus]
command = ["check-procs", "-p", "incusd", "-W", "1", "-C", "1"]

# Tailscale connectivity
[plugin.checks.tailscale]
command = ["check-procs", "-p", "tailscaled", "-W", "1", "-C", "1"]
EOF

  success "mackerel-agent configured."
}

start_agent() {
  info "Enabling and starting mackerel-agent..."
  run_sudo systemctl enable mackerel-agent
  run_sudo systemctl restart mackerel-agent

  if run_sudo systemctl is-active --quiet mackerel-agent; then
    success "mackerel-agent is running."
  else
    error "mackerel-agent failed to start. Check: journalctl -u mackerel-agent.service"
    exit 1
  fi
}

# --- main ---

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

APIKEY="$1"
ROLE="${2:-}"

install_mackerel_agent "$APIKEY"
install_check_plugins
configure_agent "$ROLE"
start_agent

echo ""
success "Done! The host will appear in Mackerel within a few minutes."
echo "  Dashboard: https://mackerel.io/my/hosts"
if [ -n "$ROLE" ]; then
  echo "  Service:   kotarnetes"
  echo "  Role:      $ROLE"
fi
echo "  Logs:      journalctl -u mackerel-agent.service -f"
