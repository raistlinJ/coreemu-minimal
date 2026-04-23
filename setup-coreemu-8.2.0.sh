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
echo "   CoreEMU 8.2.0 Setup (Debian 11)       "
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



echo "==> Compiling CoreEMU 8.2.0 from source (required for legacy GUI)..."
cd /tmp
git clone https://github.com/coreemu/core.git
cd core
git checkout release-8.2.0

echo "==> Running CoreEMU 8.2.0 setup toolchain..."
./setup.sh

echo "==> Running Invoke installation..."
export PATH="$HOME/.local/bin:$PATH"
inv install

echo "==> Enabling and starting core-daemon..."
systemctl daemon-reload
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

echo "========================================="
echo "   Setup Complete!                       "
echo "========================================="
echo "- Basic CLI IDE tools (vim, nano) are installed."
echo "- CoreEMU backend (core-daemon) is enabled and running."
echo "- OSPF-MDR (Zebra/OSPF) routing suite is compiled and installed."
echo ""
echo "Verify status with:"
echo "  systemctl status core-daemon"
