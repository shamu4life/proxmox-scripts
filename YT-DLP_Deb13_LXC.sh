#!/bin/bash

# --- Global Variables & Colors ---
# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- ASCII Art Header ---
cat << "EOF"

${BLUE}
  __  __ _____ ____   _     _
 \ \/ /|  ___||  _ \ | |   | |
  \  / | |_   | | | || |   | |
  /  \ |  _|  | |_| || |___| |___
 /_/\_\|_|    |____/ |_____|_____|
${NC}
 This script automates the creation of a Proxmox LXC for yt-dlp.
 It prompts for user input, provides defaults, and handles setup automatically.

EOF

# --- Script Variables ---
TEMPLATE_OS_NAME="debian-12-standard"
ROOT_PASSWORD=""
PASSWORD_ARG=""

# --- Helper Functions ---
function msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

function msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# --- Pre-flight Checks ---
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   msg_error "This script must be run as root."
fi

if ! command -v jq &> /dev/null; then
    msg_info "'jq' is not installed. Attempting to install it now..."
    apt-get update >/dev/null && apt-get install -y jq >/dev/null
    if ! command -v jq &> /dev/null; then
        msg_error "'jq' could not be installed automatically. Please install it manually and re-run the script."
    fi
    msg_ok "'jq' has been installed."
fi

# --- Template Management ---
msg_info "Searching for the latest Debian 12 (Bookworm) template..."
pveam update >/dev/null # Ensure the list is fresh

LATEST_TEMPLATE=$(pveam available --section system | grep "$TEMPLATE_OS_NAME" | sort -V | tail -n 1 | awk '{print $2}')

if [ -z "$LATEST_TEMPLATE" ]; then
    msg_error "Could not find any Debian 12 templates. Please check your Proxmox sources."
fi
msg_ok "Found latest template: ${GREEN}$LATEST_TEMPLATE${NC}"

# --- Select Template Storage ---
msg_info "Detecting suitable storage for templates..."
mapfile -t TEMPLATE_STORAGE_POOLS < <(pvesm status --content vztmpl | tail -n +2 | awk '{print $1}')
if [ ${#TEMPLATE_STORAGE_POOLS[@]} -eq 0 ]; then
    msg_error "No storage pools that support templates (e.g., 'local') were found."
fi

echo "Please select a storage pool for the template download:"
select TEMPLATE_STORAGE in "${TEMPLATE_STORAGE_POOLS[@]}"; do
    if [[ -n "$TEMPLATE_STORAGE" ]]; then
        msg_ok "You selected '$TEMPLATE_STORAGE' for templates."
        break
    else
        echo -e "${YELLOW}Invalid selection. Please try again.${NC}"
    fi
done

if ! pveam list $TEMPLATE_STORAGE | grep -q $LATEST_TEMPLATE; then
    msg_warn "Template not found on '$TEMPLATE_STORAGE'. Downloading now..."
    pveam download $TEMPLATE_STORAGE $LATEST_TEMPLATE || msg_error "Failed to download template."
    msg_ok "Template downloaded successfully."
else
    msg_ok "Latest Debian 12 template is already available on '$TEMPLATE_STORAGE'."
fi

# --- Select Disk Storage ---
msg_info "Detecting suitable storage for the container disk..."
mapfile -t DISK_STORAGE_POOLS < <(pvesm status --content rootdir | tail -n +2 | awk '{print $1}')
if [ ${#DISK_STORAGE_POOLS[@]} -eq 0 ]; then
    msg_error "No storage pools that support containers (e.g., LVM-Thin, ZFS) were found."
fi

echo "Please select a storage pool for the container's disk:"
select DISK_STORAGE in "${DISK_STORAGE_POOLS[@]}"; do
    if [[ -n "$DISK_STORAGE" ]]; then
        msg_ok "You selected '$DISK_STORAGE' for the disk."
        break
    else
        echo -e "${YELLOW}Invalid selection. Please try again.${NC}"
    fi
done

# --- Gather User Input ---
msg_info "Please provide the following details for the new container."

NEXT_ID=$(pvesh get /cluster/nextid)
read -p "Enter Container ID [default: $NEXT_ID]: " CT_ID
CT_ID=${CT_ID:-$NEXT_ID}

read -p "Enter Hostname [default: yt-dlp]: " HOSTNAME
HOSTNAME=${HOSTNAME:-yt-dlp}

if [ -t 0 ]; then
    msg_info "Running in interactive mode. Please set a root password."
    while true; do
        read -sp "Enter root password: " ROOT_PASSWORD
        echo
        read -sp "Confirm root password: " ROOT_PASSWORD_CONFIRM
        echo
        if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] && [[ -n "$ROOT_PASSWORD" ]]; then
            PASSWORD_ARG="--password $ROOT_PASSWORD"
            break
        else
            echo -e "${RED}Passwords do not match or are empty. Please try again.${NC}"
        fi
    done
else
    msg_warn "Running in non-interactive mode. Creating a passwordless container."
    msg_warn "Access with 'pct enter <CTID>' from the Proxmox host."
fi

read -p "Enter CPU Cores [default: 2]: " CORES
CORES=${CORES:-2}

read -p "Enter RAM in MB [default: 4096]: " RAM
RAM=${RAM:-4096}

read -p "Enter Disk Size in GB [default: 10]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-10}

msg_info "Detecting network bridges..."
mapfile -t BRIDGES < <(pvesh get /nodes/$(hostname)/network --type bridge --output-format json | jq -r '.[].iface')
if [ ${#BRIDGES[@]} -eq 0 ]; then
    msg_error "No network bridges found."
fi

echo "Please select a network bridge:"
select BRIDGE in "${BRIDGES[@]}"; do
    if [[ -n "$BRIDGE" ]]; then
        msg_ok "You selected '$BRIDGE'."
        break
    else
        echo -e "${YELLOW}Invalid selection. Please try again.${NC}"
    fi
done

read -p "Enter static IP address (e.g., 192.168.1.50/24) or leave blank for DHCP: " IP_ADDRESS
if [ -z "$IP_ADDRESS" ]; then
    NETWORK_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
    IP_INFO="DHCP"
else
    read -p "Enter Gateway address (e.g., 192.168.1.1): " GATEWAY
    if [ -z "$GATEWAY" ]; then
        msg_error "Gateway is required for a static IP configuration."
    fi
    NETWORK_CONFIG="name=eth0,bridge=${BRIDGE},ip=${IP_ADDRESS},gw=${GATEWAY}"
    IP_INFO="Static: $IP_ADDRESS"
fi

# --- Create and Configure Container ---
msg_info "Creating LXC container... This may take a moment."

pct create $CT_ID ${TEMPLATE_STORAGE}:vztmpl/$LATEST_TEMPLATE \
    --hostname $HOSTNAME \
    $PASSWORD_ARG \
    --cores $CORES \
    --memory $RAM \
    --rootfs ${DISK_STORAGE}:${DISK_SIZE} \
    --net0 $NETWORK_CONFIG \
    --onboot 1 \
    --start 1 \
    || msg_error "Failed to create LXC container."

msg_ok "Container $CT_ID created successfully. Starting configuration..."
msg_info "Waiting for container to boot and acquire network..."
sleep 10

# --- Run all configuration steps in a single block ---
msg_info "Installing dependencies and configuring the container..."
COMMANDS="DEBIAN_FRONTEND=noninteractive apt-get update && apt-get upgrade -y; \
apt-get install -y python3-pip ffmpeg pipx locales; \
echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen; \
pipx install yt-dlp; \
pipx ensurepath"

pct exec $CT_ID -- bash -c "$COMMANDS" || msg_error "Failed during container configuration."

# --- Final Summary ---
echo -e "\n${GREEN}==========================================="
echo -e " yt-dlp Container Setup Complete! 🎉"
echo -e "===========================================${NC}\n"
echo -e "  - ${YELLOW}ID:${NC}            $CT_ID"
echo -e "  - ${YELLOW}Hostname:${NC}      $HOSTNAME"
echo -e "  - ${YELLOW}Disk Storage:${NC}  $DISK_STORAGE"
echo -e "  - ${YELLOW}IP Addr:${NC}       $IP_INFO"
echo -e "  - ${YELLOW}Cores:${NC}         $CORES"
echo -e "  - ${YELLOW}RAM:${NC}           ${RAM}MB"
echo -e "  - ${YELLOW}Disk:${NC}          ${DISK_SIZE}GB"
echo -e "\n"

if [[ -n "$PASSWORD_ARG" ]]; then
    msg_ok "Root password has been set."
else
    msg_ok "No root password was set for this container."
fi

msg_ok "Access it from the Proxmox host with the command: 'pct enter $CT_ID'"
