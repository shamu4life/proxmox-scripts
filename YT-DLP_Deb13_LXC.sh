#!/bin/bash
#
# Description: This script automates the creation and configuration of a
#              dedicated Proxmox LXC container for running yt-dlp. (v4)
#

# --- Function to handle errors ---
handle_error() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    exit 1
}

# --- Global Variables & Colors ---
TEMPLATE="debian-13-standard_13.0-1_amd64.tar.zst"
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Check for root privileges ---
if [ "$(id -u)" -ne 0 ]; then
    handle_error "This script must be run as root."
fi

# --- Main Script ---
clear

# --- ASCII Art Header ---
cat << "EOF"
__  ________    ____  __    ____ 
\ \/ /_  __/   / __ \/ /   / __ \
 \  / / /_____/ / / / /   / /_/ /
 / / / /_____/ /_/ / /___/ ____/ 
/_/ /_/     /_____/_____/_/      
                                 


EOF

echo -e "${GREEN}--- Proxmox yt-dlp LXC Creation Script ---${NC}"
echo "This script will guide you through creating a new Debian 13 container."

# --- Gather System Information ---
echo -e "\n${YELLOW}Gathering system information...${NC}"

# Get the next available container ID
SUGGESTED_ID=$(pvesh get /cluster/nextid)
echo "✔️ Suggested CT ID: ${SUGGESTED_ID}"

# Get storage locations for templates and images separately
mapfile -t TEMPLATE_STORAGE_OPTIONS < <(pvesm status --content vztmpl | awk 'NR>1 {print $1}')
mapfile -t DISK_STORAGE_OPTIONS < <(pvesm status --content images | awk 'NR>1 {print $1}')


# --- NEW: Self-Correction Logic ---
if [ ${#TEMPLATE_STORAGE_OPTIONS[@]} -eq 0 ]; then
    echo -e "\n${RED}Configuration Issue Detected!${NC}"
    echo "No storage is configured to hold 'Container templates' (vztmpl)."
    
    # Check if a 'local' storage exists to offer a solution
    if pvesm status | awk 'NR>1 {print $1}' | grep -q "^local$"; then
        echo -e "\nYour '${YELLOW}local${NC}' storage is a good candidate for this."
        echo "To fix this, please run the following command on your Proxmox host:"
        
        # Get existing content and suggest the new command
        EXISTING_CONTENT=$(pvesm status --storage local --output-format json-pretty | jq -r '.content')
        if [[ -z "$EXISTING_CONTENT" || "$EXISTING_CONTENT" == "null" ]]; then
            NEW_CONTENT="vztmpl"
        else
            NEW_CONTENT="${EXISTING_CONTENT},vztmpl"
        fi
        
        echo -e "\n  ${GREEN}pvesm set local --content $NEW_CONTENT${NC}\n"
        echo "After running the command, please re-run this script."
    else
        echo "Please enable the 'vztmpl' content type on one of your storage pools in the Proxmox UI."
    fi
    exit 1 # Exit gracefully after providing the solution
fi
# --- END of Self-Correction Logic ---


if [ ${#DISK_STORAGE_OPTIONS[@]} -eq 0 ]; then
    handle_error "No storage found that supports 'images' (container disks). Please check your storage configuration."
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

# Storage Selection Menus
echo -e "\nPlease select a storage location for the TEMPLATE:"
select STORAGE_TMPL in "${TEMPLATE_STORAGE_OPTIONS[@]}"; do
    [[ -n "$STORAGE_TMPL" ]] && break || echo "Invalid selection."
done

echo -e "\nPlease select a storage location for the CONTAINER DISK:"
select STORAGE_DISK in "${DISK_STORAGE_OPTIONS[@]}"; do
    [[ -n "$STORAGE_DISK" ]] && break || echo "Invalid selection."
done

echo -e "\nPlease select a network bridge:"
select BRIDGE in "${BRIDGE_OPTIONS[@]}"; do
    [[ -n "$BRIDGE" ]] && break || echo "Invalid selection."
done

read -p "Enter IP Address (e.g., 192.168.1.50/24) or leave blank for DHCP: " IP_ADDRESS
if [ -z "$IP_ADDRESS" ]; then
    IP_CONFIG="dhcp"
else
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
echo "  Template Storage: $STORAGE_TMPL"
echo "  Disk Storage:     $STORAGE_DISK"
echo "  Bridge:         $BRIDGE"
echo "  IP Config:      $IP_CONFIG"
echo -e "${YELLOW}----------------------------${NC}\n"

read -p "Proceed with creation? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Creation cancelled by user."
    exit 0
fi

# --- Step 1: Template Management ---
echo -e "\n${GREEN}Checking for Debian 13 template ($TEMPLATE) on '$STORAGE_TMPL'...${NC}"
if ! pvesm list "$STORAGE_TMPL" --vztmpl | grep -q "$TEMPLATE"; then
    echo "Template not found. Attempting to download..."
    pveam update || handle_error "Failed to update PVE template list."
    pveam download "$STORAGE_TMPL" "$TEMPLATE" || handle_error "Failed to download template."
    echo "Template downloaded successfully."
else
    echo "Template already exists on storage '$STORAGE_TMPL'."
fi

# --- Step 2: Create Container ---
echo -e "\n${GREEN}Creating LXC container...${NC}"
IP_SETTING="ip=${IP_CONFIG}"

pct create "$CT_ID" "$STORAGE_TMPL:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --password "$ROOT_PASSWORD" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "$STORAGE_DISK:$DISK_SIZE" \
    --net0 name=eth0,bridge="$BRIDGE","$IP_SETTING" \
    --onboot 1 \
    --start 1 || handle_error "Failed to create the LXC container with 'pct create'."

echo "Container created. Waiting for it to boot and establish network..."
sleep 15

# --- Step 3: Post-Install Configuration ---
echo -e "\n${GREEN}Updating container and installing yt-dlp...${NC}"
INSTALL_SUCCESS=false
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
