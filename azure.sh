#!/bin/bash
# azure.sh - Provision Azure infrastructure for Machnet replication
# Run this from Azure Cloud Shell (or anywhere with az CLI logged in).
# Creates: vnet, NSG (SSH), and 2x Standard_F4s_v2 VMs, each with:
#   - eth0: management NIC (public IP, SSH)
#   - eth1: accelerated-networking NIC (dedicated to Machnet/DPDK)
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

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}➜${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }

# ---------------- Resource group ----------------
info "Ensuring resource group '$RG' exists in $LOCATION..."
az group create -n "$RG" -l "$LOCATION" -o none
ok "Resource group ready."

# ---------------- Network ----------------
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

# ---------------- VMs ----------------
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

# ---------------- Summary ----------------
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
  echo "  SSH:              ssh ${ADMIN_USER}@${PUB_IP}"
  echo "  Machnet IP (eth1): ${ETH1_IP}"
done
echo ""
echo "Next steps (on EACH VM):"
echo "  git clone <your-repo-url> && cd <your-repo>"
echo "  ./setup.sh"
echo ""
echo "Use the server node's Machnet IP (eth1) when the client asks for it."
echo ""
echo "When finished, delete everything with:"
echo "  az group delete -n $RG --yes --no-wait"
