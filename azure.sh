#!/bin/bash
# Provision or tear down Azure infrastructure for Machnet replication
# Run this from Azure Cloud Shell (or anywhere with az CLI logged in).
#
# Menu:
#   1) Install - create vnet, NSG (SSH), and 2x Standard_F4s_v2 VMs, each with:
#        - eth0: management NIC (public IP, SSH)
#        - eth1: accelerated-networking NIC (dedicated to Machnet/DPDK)
#   2) Delete  - delete the entire resource group (stops all billing)
#   3) Exit
#
# Usage: ./azure.sh

set -euo pipefail

# ---------------- Config ----------------
RG="machnet"
LOCATION="denmarkeast"
ZONE="1"
VM_SIZE="Standard_F4s_v2"
IMAGE="Ubuntu2204"
ADMIN_USER="azureuser"
VNET="machnet-vnet"
SUBNET="default"
NSG="machnet-nsg"
NODES=(node1 node2)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
BOLD='\033[1m'
info()  { echo -e "${BLUE}➜${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# ---------------- Install ----------------
install_infra() {
    info "Ensuring resource group '$RG' exists in $LOCATION..."
    az group create -n "$RG" -l "$LOCATION" -o none
    ok "Resource group ready."

    info "Creating vnet '$VNET'..."
    az network vnet create -g "$RG" -n "$VNET" \
      --address-prefix 10.0.0.0/16 \
      --subnet-name "$SUBNET" --subnet-prefix 10.0.0.0/24 -o none
    ok "VNet ready."

    info "Creating NSG '$NSG' with SSH rule..."
    az network nsg create -g "$RG" -n "$NSG" -o none
    az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-ssh \
      --priority 1000 --protocol Tcp --destination-port-ranges 22 \
      --access Allow --direction Inbound -o none
    az network vnet subnet update -g "$RG" --vnet-name "$VNET" \
      -n "$SUBNET" --network-security-group "$NSG" -o none
    ok "NSG attached to subnet."

    for NODE in "${NODES[@]}"; do
      info "Creating $NODE (public IP + 2 NICs + VM)..."

      az network public-ip create -g "$RG" -n "${NODE}-pip" \
        --sku Standard --zone "$ZONE" -o none

      # eth0: management NIC (SSH stays alive on this one)
      az network nic create -g "$RG" -n "${NODE}-eth0" \
        --vnet-name "$VNET" --subnet "$SUBNET" \
        --public-ip-address "${NODE}-pip" -o none

      # eth1: accelerated networking NIC (Machnet/DPDK takes this one over)
      az network nic create -g "$RG" -n "${NODE}-eth1" \
        --vnet-name "$VNET" --subnet "$SUBNET" \
        --accelerated-networking true -o none

      # NIC order matters: eth0 first (management), eth1 second (Machnet)
      az vm create -g "$RG" -n "$NODE" \
        --image "$IMAGE" --size "$VM_SIZE" --zone "$ZONE" \
        --nics "${NODE}-eth0" "${NODE}-eth1" \
        --admin-username "$ADMIN_USER" --generate-ssh-keys -o none

      ok "$NODE created."
    done

    echo ""
    echo "==========================================="
    echo "  DEPLOYMENT COMPLETE"
    echo "==========================================="
    for NODE in "${NODES[@]}"; do
      PUB_IP=$(az network public-ip show -g "$RG" -n "${NODE}-pip" --query ipAddress -o tsv)
      ETH1_IP=$(az network nic show -g "$RG" -n "${NODE}-eth1" \
        --query "ipConfigurations[0].privateIPAddress" -o tsv)
      echo ""
      echo "$NODE:"
      echo "  SSH:               ssh ${ADMIN_USER}@${PUB_IP}"
      echo "  Machnet IP (eth1): ${ETH1_IP}"
    done
    echo ""
    echo "Next steps (on EACH VM):"
    echo "  git clone <your-repo-url> && cd <your-repo>"
    echo "  export GITHUB_USER=... GITHUB_PAT=..."
    echo "  ./setup.sh"
    echo ""
    echo "Use the server node's Machnet IP (eth1) when the client asks for it."
}

# ---------------- Delete ----------------
delete_infra() {
    if ! az group exists -n "$RG" | grep -qi true; then
        warn "Resource group '$RG' does not exist. Nothing to delete."
        return 0
    fi

    warn "This will DELETE resource group '$RG' and EVERYTHING in it:"
    az resource list -g "$RG" --query "[].{Name:name, Type:type}" -o table 2>/dev/null || true
    echo ""
    read -rp "Type 'delete' to confirm: " confirm
    if [ "$confirm" != "delete" ]; then
        warn "Aborted. Nothing was deleted."
        return 0
    fi

    info "Deleting resource group '$RG' (runs in background)..."
    az group delete -n "$RG" --yes --no-wait
    ok "Delete started. Billing stops as resources are removed (takes a few minutes)."
    echo "  Check status with: az group exists -n $RG"
}

# ---------------- Main menu ----------------
main() {
    echo -e "${BOLD}===========================================${NC}"
    echo -e "${BOLD}    MACHNET AZURE INFRASTRUCTURE${NC}"
    echo -e "${BOLD}===========================================${NC}"
    echo "  RG: $RG | Region: $LOCATION | Size: $VM_SIZE x${#NODES[@]}"

    while true; do
        echo ""
        echo "Select action:"
        echo "  1) Install (create VMs + network)"
        echo "  2) Delete  (tear down everything, stop billing)"
        echo "  3) Exit"
        read -rp "Choice [1-3]: " choice
        case "$choice" in
            1) install_infra; break ;;
            2) delete_infra; break ;;
            3) info "Exiting."; break ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

main
