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
echo "   CoreEMU 8.2.0 & Docker Setup (Debian 11) "
echo "========================================="

# Ensure sbin directories are in PATH (fixes "ldconfig not found" on minimal debian via sudo/su)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating system packages..."
apt-get update
apt-get upgrade -y

echo "==> Installing basic CLI tools, dependencies, and network daemons..."
apt-get install -y curl wget jq git vim nano htop build-essential ca-certificates software-properties-common tcpdump tshark python3-venv python3-pip python3.9-venv python3-tk libtool gawk libreadline-dev automake pkg-config

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

echo "==> Fetching CoreEMU 8.2.0 release..."
CORE_URL="https://github.com/coreemu/core/releases/download/release-8.2.0/core_distributed_8.2.0_amd64.deb"

echo "==> Downloading CoreEMU from $CORE_URL"
wget -qO coreemu.deb "$CORE_URL"

echo "==> Installing CoreEMU and system dependencies..."
# Using apt install ./package.deb automatically resolves and installs dependencies
apt-get install -y ./coreemu.deb

echo "==> Creating systemd service for CoreEMU 8.2.0..."
cat << 'EOF' > /etc/systemd/system/core-daemon.service
[Unit]
Description=Common Open Research Emulator Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '$(command -v core-daemon)'
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "==> Enabling and starting core-daemon..."
systemctl enable core-daemon
systemctl restart core-daemon

echo "==> Compiling and Installing OSPF-MDR (Zebra)..."
# CoreEMU natively expects Zebra from Quagga/OSPF-MDR
git clone https://github.com/USNavalResearchLaboratory/ospf-mdr.git /tmp/ospf-mdr
cd /tmp/ospf-mdr
./bootstrap.sh
./configure --disable-doc --enable-user=root --enable-group=root --with-cflags=-ggdb --sysconfdir=/usr/local/etc/quagga --enable-vtysh --localstatedir=/var/run/quagga
make -j $(nproc)
make install
cd -
rm -rf /tmp/ospf-mdr

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
