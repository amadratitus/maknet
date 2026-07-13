#!/bin/bash
# setup.sh - Prepare a fresh Azure Ubuntu VM for Machnet and launch the benchmark script.
# Run this ON EACH VM after cloning your repo:
#   export GITHUB_USER=your_username
#   export GITHUB_PAT=ghp_xxxxxxxxxxxx
#   ./setup.sh
#
# Installs: docker, jq, curl, driverctl, git
# Then hands off to auto_machnet.sh in the same directory.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${BLUE}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------- Sanity checks ----------------
if [ "$(id -u)" -eq 0 ]; then
  error "Run this as the normal user (azureuser), not root. It uses sudo where needed."
  exit 1
fi

if [ -z "${GITHUB_PAT:-}" ] || [ -z "${GITHUB_USER:-}" ]; then
  error "GITHUB_USER and/or GITHUB_PAT not set."
  echo "Export them first:"
  echo "  export GITHUB_USER=your_username"
  echo "  export GITHUB_PAT=ghp_xxxxxxxxxxxxxxxx"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/auto_machnet.sh" ]; then
  error "auto_machnet.sh not found next to setup.sh. Run this from inside the cloned repo."
  exit 1
fi

# ---------------- Install packages ----------------
info "Installing dependencies (docker, jq, curl, driverctl, git)..."
sudo apt-get update -y
sudo apt-get install -y docker.io jq curl driverctl git
ok "Packages installed."

info "Enabling and starting Docker..."
sudo systemctl enable --now docker
ok "Docker running."

# ---------------- Docker group ----------------
if ! id -nG "$USER" | grep -qw docker; then
  info "Adding $USER to docker group..."
  sudo usermod -aG docker "$USER"
  ok "Added to docker group."
fi

chmod +x "$SCRIPT_DIR/auto_machnet.sh"

# ---------------- Hand off to auto_machnet.sh ----------------
# Group membership doesn't apply to the current shell session, so run the
# machnet script under the docker group via sg. -E-style env passthrough:
# sg starts a fresh shell, so re-export the credentials explicitly.
info "Launching auto_machnet.sh..."
exec sg docker -c "export GITHUB_USER='$GITHUB_USER' GITHUB_PAT='$GITHUB_PAT'; cd '$SCRIPT_DIR' && ./auto_machnet.sh"
