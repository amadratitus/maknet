#!/bin/bash
# auto_machnet.sh - One‑command Machnet deployment on Azure
# Usage: ./auto_machnet.sh

set -euo pipefail

# --------------------------------
#  Colors & formatting
# --------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

info()  { echo -e "${BLUE}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# --------------------------------
#  Dependency checks
# --------------------------------
check_deps() {
    local missing=()
    for cmd in docker jq curl driverctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing required commands: ${missing[*]}"
        echo "Install them with:"
        echo "  sudo apt update && sudo apt install -y docker.io jq curl driverctl"
        echo "Then add your user to the docker group:"
        echo "  sudo usermod -aG docker $USER && newgrp docker"
        exit 1
    fi
    ok "All required commands found."
}

# --------------------------------
#  Check GITHUB_PAT and GITHUB_USER
# --------------------------------
check_github_creds() {
    if [ -z "${GITHUB_PAT:-}" ]; then
        error "GITHUB_PAT environment variable not set."
        echo "Please export your GitHub Personal Access Token:"
        echo "  export GITHUB_PAT=ghp_xxxxxxxxxxxxxxxxxxxx"
        exit 1
    fi
    if [ -z "${GITHUB_USER:-}" ]; then
        error "GITHUB_USER environment variable not set."
        echo "Please export your GitHub username:"
        echo "  export GITHUB_USER=your_username"
        exit 1
    fi
    ok "GitHub credentials found."
}

# --------------------------------
#  Docker login & pull (only if image missing)
# --------------------------------
ensure_docker_image() {
    local IMAGE="ghcr.io/microsoft/machnet/machnet:latest"
    if docker image inspect "$IMAGE" &>/dev/null; then
        ok "Machnet Docker image already present."
        return 0
    fi

    info "Logging into GitHub Container Registry..."
    echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin >/dev/null 2>&1
    ok "Login successful."

    info "Pulling Machnet image (this may take a few minutes)..."
    docker pull "$IMAGE"
    ok "Image pulled successfully."
}

# --------------------------------
#  Detect Azure secondary NIC (interface[1])
# --------------------------------
detect_azure_nic() {
    info "Detecting Azure secondary NIC via metadata service..."
    local metadata=$(curl -s -H Metadata:true --noproxy "*" \
        "http://169.254.169.254/metadata/instance?api-version=2021-02-01")

    MACHNET_IP=$(echo "$metadata" | jq -r '.network.interface[1].ipv4.ipAddress[0].privateIpAddress')
    MACHNET_MAC=$(echo "$metadata" | jq -r '.network.interface[1].macAddress' | sed 's/\(..\)/\1:/g;s/:$//')

    if [ -z "$MACHNET_IP" ] || [ -z "$MACHNET_MAC" ]; then
        error "Could not retrieve IP/MAC from Azure metadata. Are you running on Azure?"
        exit 1
    fi

    ok "Machnet IP  : $MACHNET_IP"
    ok "Machnet MAC : $MACHNET_MAC"
}

# --------------------------------
#  Prepare Azure NIC (unbind eth1)
# --------------------------------
prepare_azure_nic() {
    info "Preparing Azure NIC (loading uio_hv_generic, unbinding eth1)..."
    sudo modprobe uio_hv_generic
    if [ -d /sys/class/net/eth1 ]; then
        DEV_UUID=$(basename "$(readlink /sys/class/net/eth1/device)" 2>/dev/null || true)
        if [ -n "$DEV_UUID" ]; then
            sudo driverctl -b vmbus set-override "$DEV_UUID" uio_hv_generic
            ok "Unbound eth1 ($DEV_UUID) from hv_netvsc."
        else
            warn "Could not find device UUID for eth1; maybe already unbound?"
        fi
    else
        warn "eth1 not found; assuming NIC is already prepared."
    fi
}

# --------------------------------
#  Start Machnet sidecar (using official machnet.sh)
# --------------------------------
start_machnet() {
    info "Starting Machnet sidecar (using official machnet.sh)..."
    # Ensure we are in the machnet repo directory
    if [ ! -f "machnet.sh" ]; then
        warn "machnet.sh not found in current directory. Cloning repository..."
        git clone --recursive https://github.com/microsoft/machnet.git
        cd machnet
    fi

    # Run machnet.sh in background, redirect logs
    ./machnet.sh --mac "$MACHNET_MAC" --ip "$MACHNET_IP" > machnet.log 2>&1 &
    MACHNET_PID=$!
    info "Machnet sidecar started with PID $MACHNET_PID (logs: machnet.log)"

    # Wait for it to be ready (simple sleep; could check socket)
    sleep 5
    ok "Machnet should be ready."
}

# --------------------------------
#  Run msg_gen benchmark (via Docker)
# --------------------------------
run_benchmark() {
    local mode="$1"   # "server" or "client"
    local server_ip="$2"

    local IMAGE="ghcr.io/microsoft/machnet/machnet:latest"
    local MSG_GEN="docker run --rm -v /var/run/machnet:/var/run/machnet $IMAGE release_build/src/apps/msg_gen/msg_gen"

    local TIMESTAMP=$(date +%F_%H-%M-%S)
    local RESULT_DIR="results_$TIMESTAMP"
    mkdir -p "$RESULT_DIR"
    local RESULT_FILE="$RESULT_DIR/benchmark.txt"

    if [ "$mode" == "server" ]; then
        info "Starting msg_gen server..."
        $MSG_GEN --local_ip "$MACHNET_IP" | tee "$RESULT_FILE"
    else
        info "Running msg_gen client against $server_ip..."
        echo "Machnet benchmark results" > "$RESULT_FILE"
        echo "==========================" >> "$RESULT_FILE"
        echo "Server IP: $server_ip" >> "$RESULT_FILE"
        echo "Client IP: $MACHNET_IP" >> "$RESULT_FILE"
        echo "Timestamp: $(date)" >> "$RESULT_FILE"
        echo "" >> "$RESULT_FILE"

        # Loop over message sizes and inflight counts
        for SIZE in 64 256 1024 4096; do
            for INFLIGHT in 1 16 128 512; do
                echo "-----------------------------------" | tee -a "$RESULT_FILE"
                echo "SIZE=${SIZE}B, INFLIGHT=${INFLIGHT}" | tee -a "$RESULT_FILE"
                echo "-----------------------------------" | tee -a "$RESULT_FILE"
                $MSG_GEN \
                    --local_ip "$MACHNET_IP" \
                    --remote_ip "$server_ip" \
                    --msg_size "$SIZE" \
                    --inflight "$INFLIGHT" \
                    --duration 30 \
                    >> "$RESULT_FILE" 2>&1
                echo "" >> "$RESULT_FILE"
            done
        done
        ok "Benchmark complete. Results saved in $RESULT_FILE"
    fi
}

# --------------------------------
#  Cleanup (trap)
# --------------------------------
cleanup() {
    if [ -n "${MACHNET_PID:-}" ]; then
        info "Stopping Machnet sidecar (PID $MACHNET_PID)..."
        kill "$MACHNET_PID" 2>/dev/null || true
        wait "$MACHNET_PID" 2>/dev/null || true
    fi
    ok "Cleanup done."
}
trap cleanup EXIT SIGINT SIGTERM

# --------------------------------
#  Main menu
# --------------------------------
main() {
    echo -e "${BOLD}===========================================${NC}"
    echo -e "${BOLD}       MACHNET AUTOMATED SETUP${NC}"
    echo -e "${BOLD}===========================================${NC}"

    check_deps
    check_github_creds
    detect_azure_nic
    ensure_docker_image
    prepare_azure_nic
    start_machnet

    # Menu
    while true; do
        echo ""
        echo "Select Mode:"
        echo "  1) Server"
        echo "  2) Client"
        echo "  3) Exit"
        read -rp "Choice [1-3]: " choice
        case "$choice" in
            1)
                run_benchmark "server" ""
                break
                ;;
            2)
                read -rp "Enter server Machnet IP: " server_ip
                if [ -z "$server_ip" ]; then
                    error "Server IP required."
                    continue
                fi
                run_benchmark "client" "$server_ip"
                break
                ;;
            3)
                info "Exiting."
                break
                ;;
            *)
                warn "Invalid choice."
                ;;
        esac
    done
}

# --------------------------------
#  Run main
# --------------------------------
main
