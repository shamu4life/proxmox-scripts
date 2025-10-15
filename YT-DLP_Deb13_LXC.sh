#!/bin/bash

# This script automates the creation and configuration of a 
# Proxmox LXC container specifically for running yt-dlp.
# Version 2.0 - Improved compatibility for older Proxmox VE versions.

# --- Exit on any error ---
set -e

# --- Color Definitions ---
YLW='\033[1;33m'
GRN='\033[1;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Function to display header ---
header_info() {
    clear
    echo -e "${GRN}############################################################${NC}"
    echo -e "${GRN}#                                                          #${NC}"
    echo -e "${GRN}#          Proxmox yt-dlp LXC Container Creator            #${NC}"
    echo -e "${GRN}#                                                          #${NC}"
    echo -e "${GRN}############################################################${NC}"
    echo
}

# --- Pre-flight Checks ---
# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root. Aborting.${NC}" 
   exit 1
fi

# --- Template Management ---
header_info
echo -e "${YLW}Checking for Debian 13 (Trixie) template...${NC}"
TEMPLATE_STORAGE="local"
TEMPLATE_NAME="debian-13-standard"
# Find the full template filename using grep/awk for wider compatibility
TEMPLATE_FILE=$(pveam list $TEMPLATE_STORAGE | grep "$TEMPLATE_NAME" | awk '{print $1}' | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
    echo "Debian 13 template not found."
    read -p "Do you want to download it now? (y/n): " DOWNLOAD_TEMPLATE
    if [[ "$DOWNLOAD_TEMPLATE" =~ ^[Yy]$ ]]; then
        echo "Updating template list..."
        pveam update
        echo "Downloading Debian 13 template..."
        pveam download $TEMPLATE_STORAGE $TEMPLATE_NAME
        # Re-check for the template file name
        TEMPLATE_FILE=$(pveam list $TEMPLATE_STORAGE | grep "$TEMPLATE_NAME" | awk '{print $1}' | head -n 1)
        if [ -z "$TEMPLATE_FILE" ]; then
            echo -e "${RED}Failed to download the template. Please check storage and network. Aborting.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Template is required to proceed. Aborting.${NC}"
        exit 1
    fi
else
    echo -e "${GRN}Debian 13 template found: $TEMPLATE_FILE${NC}"
fi
sleep 2

# --- Gather Container Information ---
header_info
echo -e "${YLW}Please provide the details for the new container.${NC}"
echo

# Get the next available CT ID from Proxmox
NEXT_ID=$(pvesh get /cluster/nextid)

# Prompt for user input with defaults
read -p "Enter Container ID [$NEXT_ID]: " CT_ID
CT_ID=${CT_ID:-$NEXT_ID}

read -p "Enter Hostname [yt-dlp]: " HOSTNAME
HOSTNAME=${HOSTNAME:-yt-dlp}

while true; do
    read -s -p "Enter Root Password: " PASSWORD
    echo
    read -s -p "Confirm Root Password: " PASSWORD2
    echo
    [ "$PASSWORD" = "$PASSWORD2" ] && ! [ -z "$PASSWORD" ] && break
    echo -e "${RED}Passwords do not match or are empty. Please try again.${NC}"
done

read -p "Enter CPU Cores [2]: " CORES
CORES=${CORES:-2}

read -p "Enter RAM in MB [4096]: " RAM
RAM=${RAM:-4096}

read -p "Enter Disk Size in GB [10]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-10}

# --- Storage Selection ---
header_info
echo -e "${YLW}Please select a storage pool for the container's root disk.${NC}"
# Use awk to parse text output for wider compatibility
mapfile -t storage_options < <(pvesh get /storage | awk 'NR>1 && ($4 ~ /rootdir/ || $4 ~ /images/) {print $1}')
PS3="Select storage: "
select STORAGE in "${storage_options[@]}"; do
    if [[ -n $STORAGE ]]; then
        echo -e "${GRN}Selected storage: $STORAGE${NC}"
        break
    else
        echo -e "${RED}Invalid selection. Please try again.${NC}"
    fi
done
sleep 1

# --- Network Configuration ---
header_info
echo -e "${YLW}Please select a network bridge.${NC}"
# Use awk to parse text output for wider compatibility
mapfile -t bridge_options < <(pvesh get /nodes/$(hostname)/network --type bridge | awk 'NR>1 {print $2}')
PS3="Select bridge: "
select BRIDGE in "${bridge_options[@]}"; do
    if [[ -n $BRIDGE ]]; then
        echo -e "${GRN}Selected bridge: $BRIDGE${NC}"
        break
    else
        echo -e "${RED}Invalid selection. Please try again.${NC}"
    fi
done
echo

read -p "Enter IP address with CIDR (e.g., 192.168.1.50/24) or leave blank for DHCP: " IP_CIDR
if [ -z "$IP_CIDR" ]; then
    NETWORK_OPTS="--net0 name=eth0,bridge=$BRIDGE,ip=dhcp"
    IP_INFO="DHCP"
else
    read -p "Enter Gateway IP: " GATEWAY
    if [ -z "$GATEWAY" ]; then
        echo -e "${RED}Gateway is required for a static IP. Aborting.${NC}"
        exit 1
    fi
    NETWORK_OPTS="--net0 name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY"
    IP_INFO="$IP_CIDR (gw: $GATEWAY)"
fi
# Use host's DNS settings
HOST_DNS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | head -n 1)

# --- Create & Configure ---
header_info
echo -e "${YLW}Creating container...${NC}"

pct create $CT_ID "$TEMPLATE_FILE" \
    --hostname "$HOSTNAME" \
    --password "$PASSWORD" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --onboot 1 \
    --nameserver "$HOST_DNS" \
    $NETWORK_OPTS

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create container. Please check settings and try again.${NC}"
    exit 1
fi

echo -e "${GRN}Container created successfully. Starting...${NC}"
pct start $CT_ID

echo -e "${YLW}Waiting for container network to initialize...${NC}"
# Wait up to 2 minutes for an IP address
for i in {1..120}; do
    CT_IP=$(pct exec $CT_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ ! -z "$CT_IP" ]; then
        echo -e "${GRN}Container IP found: $CT_IP${NC}"
        break
    fi
    sleep 1
done

if [ -z "$CT_IP" ]; then
    echo -e "${RED}Error: Could not get container IP after 120 seconds. Aborting post-install.${NC}"
    exit 1
fi

echo -e "${YLW}Updating container and installing software (yt-dlp, ffmpeg, aria2)...${NC}"
pct exec $CT_ID -- apt-get update
pct exec $CT_ID -- apt-get upgrade -y
pct exec $CT_ID -- apt-get install -y yt-dlp ffmpeg python3-pip aria2

# --- Summary ---
header_info
echo -e "${GRN}🎉 Setup Complete! 🎉${NC}"
echo
echo "Container details:"
echo "------------------------------------"
echo -e "CT ID:      ${YLW}$CT_ID${NC}"
echo -e "Hostname:   ${YLW}$HOSTNAME${NC}"
echo -e "IP Address: ${YLW}$CT_IP${NC}"
echo -e "Cores:      ${YLW}$CORES${NC}"
echo -e "RAM:        ${YLW}${RAM} MB${NC}"
echo -e "Disk Size:  ${YLW}${DISK_SIZE} GB${NC}"
echo -e "Bridge:     ${YLW}$BRIDGE${NC}"
echo "------------------------------------"
echo
echo "You can access the container with: ${GRN}pct enter $CT_ID${NC}"
echo
