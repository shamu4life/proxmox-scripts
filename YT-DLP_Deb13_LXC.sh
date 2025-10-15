#!/bin/bash

# #############################################################################
# Interactive script to create a Proxmox LXC container for yt-dlp
# Base OS: Debian 13 (Trixie)
#
# Version 2.0 - Hardened against non-interactive terminal environments
# Changes: All 'read' commands now explicitly listen to the keyboard TTY
#          to prevent prompts from being skipped.
# #############################################################################

# --- STOP ON ERRORS ---
set -e

# --- CONFIGURATION ---
STORAGE="local-lvm"                   # Proxmox storage pool for the container's disk
TEMPLATE_NAME="debian-13-standard"    # Name of the template to use
TEMPLATE="local:vztmpl/${TEMPLATE_NAME}_13.0-1_amd64.tar.zst"

# Default values for prompts
DEFAULT_HOSTNAME="yt-dlp"
DEFAULT_CORES="2"
DEFAULT_RAM_MB="4096"
DEFAULT_DISK_GB="10"

# --- SCRIPT LOGIC ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if ! command_exists pct || ! command_exists pveam || ! command_exists pvesh; then
    echo "❌ This script must be run on a Proxmox VE host."
    exit 1
fi

if ! pveam list local | grep -q "$TEMPLATE_NAME"; then
    echo "🟡 Debian 13 template not found. Attempting to download it now..."
    echo "⏳ Updating template list..."
    pveam update
    echo "📥 Downloading Debian 13 template... (This may take a moment)"
    pveam download local $TEMPLATE_NAME
    echo "✅ Template downloaded successfully."
else
    echo "✅ Debian 13 template already exists."
fi

echo "---"
echo "Please provide the details for the new LXC container."
echo "Press [Enter] to accept the default values shown in brackets."
echo "---"

# --- USER PROMPTS (HARDENED) ---

# Suggest next available CT ID and prompt for it
NEXT_ID=$(pvesh get /cluster/nextid)
while true; do
    printf "Enter a unique Container ID [${NEXT_ID}]: "
    read CT_ID </dev/tty
    CT_ID=${CT_ID:-$NEXT_ID}
    if ! [[ "$CT_ID" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid input. Please enter a number."
    elif pct status "$CT_ID" >/dev/null 2>&1; then
        echo "❌ Container ID $CT_ID is already in use."
        NEXT_ID=$(pvesh get /cluster/nextid)
    else
        break
    fi
done

# Prompt for Hostname with default
printf "Enter a hostname [${DEFAULT_HOSTNAME}]: "
read HOSTNAME </dev/tty
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

# Prompt for Password (Mandatory & Secure)
while true; do
    printf "Enter the root password for the container: "
    read -s PASSWORD </dev/tty
    printf "\n"
    printf "Confirm the root password: "
    read -s PASSWORD_CONFIRM </dev/tty
    printf "\n"
    if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ] && [ -n "$PASSWORD" ]; then
        break
    elif [ -z "$PASSWORD" ]; then
        echo "❌ Password cannot be empty."
    else
        echo "❌ Passwords do not match. Please try again."
    fi
done

# Prompt for CPU Cores with default and validation
while true; do
    printf "Enter the number of CPU cores [${DEFAULT_CORES}]: "
    read CORES </dev/tty
    CORES=${CORES:-$DEFAULT_CORES}
    if [[ "$CORES" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ Invalid input."; fi
done

# Prompt for RAM with default and validation
while true; do
    printf "Enter the amount of RAM in MB [${DEFAULT_RAM_MB}]: "
    read RAM_MB </dev/tty
    RAM_MB=${RAM_MB:-$DEFAULT_RAM_MB}
    if [[ "$RAM_MB" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ Invalid input."; fi
done

# Prompt for Disk Size with default and validation
while true; do
    printf "Enter the disk size in GB [${DEFAULT_DISK_GB}]: "
    read DISK_GB </dev/tty
    DISK_GB=${DISK_GB:-$DEFAULT_DISK_GB}
    if [[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ Invalid input."; fi
done

# --- Prompt for Network Bridge Selection ---
echo "---"
echo "Available network bridges:"
mapfile -t bridges < <(ip -br link show type bridge | awk '{print $1}')
if [ ${#bridges[@]} -eq 0 ]; then
    echo "❌ No network bridges (vmbr) found. Cannot proceed."
    exit 1
fi
select BRIDGE in "${bridges[@]}"; do
    if [ -n "$BRIDGE" ]; then
        echo "✅ You selected bridge: $BRIDGE"
        break
    else
        echo "❌ Invalid selection. Please try again."
    fi
done

# Prompt for Network Configuration (DHCP or Static)
NET_CONFIG="ip=dhcp"
IP_ADDRESS=""
GATEWAY=""
while true; do
    printf "Enter static IP (e.g., 192.168.1.50/24) or leave blank for DHCP: "
    read IP_ADDRESS_INPUT </dev/tty
    if [ -z "$IP_ADDRESS_INPUT" ]; then
        echo "✅ Using DHCP for network configuration."
        break
    elif [[ "$IP_ADDRESS_INPUT" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        IP_ADDRESS=$IP_ADDRESS_INPUT
        printf "Enter the gateway IP address (e.g., 192.168.1.1): "
        read GATEWAY_INPUT </dev/tty
        if [[ "$GATEWAY_INPUT" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            GATEWAY=$GATEWAY_INPUT
            NET_CONFIG="ip=${IP_ADDRESS},gw=${GATEWAY}"
            break
        else
            echo "❌ Invalid gateway format. Please use x.x.x.x format."
        fi
    else
        echo "❌ Invalid format. Use CIDR notation (e.g., 192.168.1.50/24) or leave blank."
    fi
done
echo "---"

# --- CONFIRMATION ---
echo "⚙️  Review the configuration:"
echo "--------------------------------"
echo "Container ID:   $CT_ID"
echo "Hostname:       $HOSTNAME"
echo "CPU Cores:      $CORES"
echo "RAM:            $RAM_MB MB"
echo "Disk Size:      $DISK_GB GB"
echo "Network Bridge: $BRIDGE"
if [ -n "$IP_ADDRESS" ]; then
    echo "IP Address:     $IP_ADDRESS (Static)"
    echo "Gateway:        $GATEWAY"
else
    echo "IP Address:     DHCP"
fi
echo "Storage Pool:   $STORAGE"
echo "Base OS:        Debian 13 (Trixie)"
echo "--------------------------------"

printf "Proceed with creation? (y/N): "
read CONFIRM </dev/tty
if [[ ! "$CONFIRM" =~ ^[yY](es)*$ ]]; then
    echo "🚫 Creation cancelled."
    exit 1
fi

# --- CONTAINER CREATION ---
echo "🔥 Creating LXC container $CT_ID ($HOSTNAME)..."

pct create $CT_ID $TEMPLATE \
    --hostname $HOSTNAME \
    --password $PASSWORD \
    --cores $CORES \
    --memory $RAM_MB \
    --rootfs $STORAGE:$DISK_GB \
    --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG \
    --onboot 1 \
    --start 1

echo "⏳ Waiting for container to boot and get a network connection..."
sleep 15

echo "🚀 Container created. Now configuring software..."
pct exec $CT_ID -- bash -c "apt-get update && apt-get upgrade -y"
echo "✅ System updated."
pct exec $CT_ID -- bash -c "apt-get install -y ffmpeg python3-pip"
echo "✅ Dependencies installed."
pct exec $CT_ID -- bash -c "pip install yt-dlp"
echo "✅ yt-dlp installed."

if [ -n "$GATEWAY" ]; then
    CT_IP="${IP_ADDRESS%/*}"
else
    CT_IP=$(pct exec $CT_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi

echo ""
echo "🎉 --- Success! --- 🎉"
echo "LXC Container '$HOSTNAME' (ID: $CT_ID) is ready."
echo "IP Address: $CT_IP"
echo "Access with: ssh root@$CT_IP"

exit 0
