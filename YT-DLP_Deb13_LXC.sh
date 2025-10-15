#!/bin/bash
#
# Description: This script automates the creation and configuration of a
#              dedicated Proxmox LXC container for running yt-dlp.
#

# --- Global Variables & Colors ---
TEMPLATE="debian-13-standard_13.0-1_amd64.tar.zst"
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Function to handle errors ---
handle_error() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    exit 1
}

# --- Check for root privileges ---
if [ "$(id -u)" -ne 0 ]; then
    handle_error "This script must be run as root."
fi

# --- Main Script ---
clear
echo -e "${GREEN}--- Proxmox yt-dlp LXC Creation Script ---${NC}"
echo "This script will guide you through creating a new Debian 13 container."

# --- Gather System Information ---
echo -e "\n${YELLOW}Gathering system information...${NC}"

# Get the next available container ID from Proxmox
SUGGESTED_ID=$(pvesh get /cluster/nextid)
echo "✔️ Suggested CT ID: ${SUGGESTED_ID}"

# Get storage locations that can hold both container images and templates
mapfile -t STORAGE_OPTIONS < <(pvesm status | awk 'NR>1 && $3 ~ /vztmpl/ && $3 ~ /images/ {print $1}')
if [ ${#STORAGE_OPTIONS[@]} -eq 0 ]; then
    handle_error "No storage found that supports both 'vztmpl' (templates) and 'images' (container disks)."
fi
echo "✔️ Found compatible storage locations."

# Get available network bridges
mapfile -t BRIDGE_OPTIONS < <(pvesh get /nodes/$(hostname)/network --output-format json | jq -r '.[] | select(.type=="bridge") | .iface')
if [ ${#BRIDGE_OPTIONS[@]} -eq 0 ]; then
    handle_error "No network bridges (e.g., vmbr0) found."
fi
echo "✔️ Found network bridges."


# --- User Prompts ---
echo -e "\n${YELLOW}Please provide the container details:${NC}"

read -p "Enter Container ID [${SUGGESTED_ID}]: " CT_ID
CT_ID=${CT_ID:-$SUGGESTED_ID}

read -p "Enter Hostname [yt-dlp]: " HOSTNAME
HOSTNAME=${HOSTNAME:-yt-dlp}

# Loop for password confirmation
while true; do
    read -s -p "Enter Root Password: " ROOT_PASSWORD
    echo
    read -s -p "Confirm Root Password: " ROOT_PASSWORD_CONFIRM
    echo
    if [ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ] && [ -n "$ROOT_PASSWORD" ]; then
        break
    else
        echo -e "${RED}Passwords do not match or are empty. Please try again.${NC}"
    fi
done

read -p "Enter CPU Cores [2]: " CORES
CORES=${CORES:-2}

read -p "Enter RAM in MB [4096]: " RAM
RAM=${RAM:-4096}

read -p "Enter Disk Size in GB [10]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-10}

# Storage Selection Menu
echo -e "\nPlease select a storage location for the container disk and template:"
select STORAGE in "${STORAGE_OPTIONS[@]}"; do
    if [[ -n "$STORAGE" ]]; then
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Network Bridge Selection Menu
echo -e "\nPlease select a network bridge:"
select BRIDGE in "${BRIDGE_OPTIONS[@]}"; do
    if [[ -n "$BRIDGE" ]]; then
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

read -p "Enter IP Address (e.g., 192.168.1.50/24) or leave blank for DHCP: " IP_ADDRESS
if [ -z "$IP_ADDRESS" ]; then
    IP_CONFIG="dhcp"
else
    # Basic validation for CIDR format
    if ! [[ $IP_ADDRESS =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]{1,2}$ ]]; then
        handle_error "Invalid static IP format. Please use CIDR notation (e.g., 192.168.1.50/24)."
    fi
    IP_CONFIG="$IP_ADDRESS"
fi

# --- Summary and Confirmation ---
echo -e "\n${YELLOW}--- Configuration Summary ---${NC}"
echo "  CT ID:          $CT_ID"
echo "  Hostname:       $HOSTNAME"
echo "  CPU Cores:      $CORES"
echo "  RAM:            ${RAM}MB"
echo "  Disk Size:      ${DISK_SIZE}GB"
echo "  Storage:        $STORAGE"
echo "  Bridge:         $BRIDGE"
echo "  IP Config:      $IP_CONFIG"
echo -e "${YELLOW}----------------------------${NC}\n"

read -p "Proceed with creation? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Creation cancelled by user."
    exit 0
fi

# --- Step 1: Template Management ---
echo -e "\n${GREEN}Checking for Debian 13 template ($TEMPLATE)...${NC}"
if ! pvesm list "$STORAGE" --vztmpl | grep -q "$TEMPLATE"; then
    echo "Template not found. Attempting to download..."
    pveam update || handle_error "Failed to update PVE template list."
    pveam download "$STORAGE" "$TEMPLATE" || handle_error "Failed to download template."
    echo "Template downloaded successfully."
else
    echo "Template already exists on storage '$STORAGE'."
fi

# --- Step 2: Create Container ---
echo -e "\n${GREEN}Creating LXC container...${NC}"
IP_SETTING="ip=${IP_CONFIG}"

pct create "$CT_ID" "$STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --password "$ROOT_PASSWORD" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge="$BRIDGE","$IP_SETTING" \
    --onboot 1 \
    --start 1 || handle_error "Failed to create the LXC container with 'pct create'."

echo "Container created. Waiting a moment for it to boot and establish network..."
sleep 15 # A generous delay to allow the container to boot and get an IP

# --- Step 3: Post-Install Configuration ---
echo -e "\n${GREEN}Updating container and installing yt-dlp...${NC}"

# Retry loop in case network isn't immediately available
for i in {1..5}; do
    if pct exec "$CT_ID" -- ping -c 1 8.8.8.8 &> /dev/null; then
        echo "Network is up. Proceeding with installation."
        pct exec "$CT_ID" -- apt-get update -y && \
        pct exec "$CT_ID" -- apt-get upgrade -y && \
        pct exec "$CT_ID" -- apt-get install -y python3-pip ffmpeg && \
        pct exec "$CT_ID" -- pip install -U yt-dlp && \
        INSTALL_SUCCESS=true
        break
    else
        echo "Network not ready yet, retrying in 10 seconds... (Attempt $i/5)"
        sleep 10
        INSTALL_SUCCESS=false
    fi
done

if ! $INSTALL_SUCCESS; then
    handle_error "yt-dlp installation failed. Could not configure the container."
fi


# --- Final Summary ---
CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')

echo -e "\n${GREEN}🎉 --- Success! --- 🎉${NC}"
echo "LXC container '$HOSTNAME' (ID: $CT_ID) has been created and configured."
echo "  IP Address:     $CT_IP"
echo "  To access the container's console, run: ${YELLOW}pct enter $CT_ID${NC}"
echo -e "${GREEN}------------------${NC}"

exit 0
