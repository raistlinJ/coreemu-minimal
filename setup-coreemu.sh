#!/bin/bash
# setup-coreemu.sh
# Automated deployment script for CoreEMU on a minimal Debian 12 Proxmox VM.

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or log in as root."
  exit 1
fi

echo "========================================="
echo "   CoreEMU & Docker Setup for Debian 12  "
echo "========================================="

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating system packages..."
apt-get update
apt-get upgrade -y

echo "==> Installing basic CLI tools, dependencies, and network daemons (Zebra/FRR)..."
apt-get install -y curl wget jq git vim nano htop build-essential ca-certificates software-properties-common frr tcpdump tshark python3-venv python3-pip

echo "==> Installing minimal graphical environment (XFCE)..."
apt-get install -y xorg xfce4 lightdm dbus-x11 x11-utils xterm

echo "==> Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    
    echo "==> Applying Docker iptables fix for CoreEMU..."
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        echo "Found existing daemon.json, merging config..."
        jq '. + {"iptables": false}' /etc/docker/daemon.json > /etc/docker/daemon.json.tmp && mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    else
        echo '{"iptables": false}' > /etc/docker/daemon.json
    fi
    
    systemctl enable docker
    systemctl start docker
    
    # Attempt to add the user running sudo to the docker group
    if [ -n "$SUDO_USER" ]; then
        echo "Adding user $SUDO_USER to the docker group..."
        usermod -aG docker "$SUDO_USER"
    else
        echo "Note: Run 'usermod -aG docker <your_user>' to manage docker without sudo."
    fi
else
    echo "Docker is already installed."
fi

echo "==> Fetching latest CoreEMU release..."
# Use GitHub API to find the latest non-distributed amd64 deb package
CORE_URL=$(curl -s https://api.github.com/repos/coreemu/core/releases/latest | jq -r '.assets[] | select(.name | endswith("_amd64.deb") and (contains("distributed") | not)) | .browser_download_url' | head -n 1)

if [ -z "$CORE_URL" ] || [ "$CORE_URL" = "null" ]; then
    echo "Warning: Failed to fetch the latest release URL from GitHub."
    echo "Defaulting to CoreEMU 9.2.1."
    CORE_URL="https://github.com/coreemu/core/releases/download/release-9.2.1/core_9.2.1_amd64.deb"
fi

echo "==> Downloading CoreEMU from $CORE_URL"
wget -qO coreemu.deb "$CORE_URL"

echo "==> Installing CoreEMU and system dependencies..."
# Using apt install ./package.deb automatically resolves and installs dependencies
apt-get install -y ./coreemu.deb

echo "==> Enabling and starting core-daemon..."
systemctl enable core-daemon
systemctl restart core-daemon

echo "==> Cleaning up..."
rm coreemu.deb

echo "========================================="
echo "   Setup Complete!                       "
echo "========================================="
echo "- Docker is installed and running."
echo "- Basic CLI IDE tools (vim, nano) are installed."
echo "- CoreEMU backend (core-daemon) is enabled and running."
echo ""
echo "Verify status with:"
echo "  systemctl status core-daemon"
echo "  docker ps"
