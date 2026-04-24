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

# Ensure sbin directories are in PATH (fixes "ldconfig not found" on minimal debian via sudo/su)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating system packages..."
apt-get update
apt-get upgrade -y

echo "==> Installing basic CLI tools, dependencies, and network daemons..."
apt-get install -y sudo curl wget jq git vim nano htop build-essential ca-certificates software-properties-common tcpdump tshark python-is-python3 python3-full python3-venv python3-pip python3.11-venv python3-tk libtool gawk libreadline-dev automake pkg-config

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

echo "==> Compiling and Installing OSPF-MDR (Zebra)..."
# CoreEMU natively expects Zebra from Quagga/OSPF-MDR
rm -rf /tmp/ospf-mdr
git clone https://github.com/USNavalResearchLaboratory/ospf-mdr.git /tmp/ospf-mdr
cd /tmp/ospf-mdr
./bootstrap.sh
export CFLAGS="-fcommon -ggdb"
./configure --disable-doc --enable-user=root --enable-group=root --with-cflags="-ggdb -fcommon" --sysconfdir=/usr/local/etc/quagga --enable-vtysh --localstatedir=/var/run/quagga
make -j $(nproc)
make install
cd -
rm -rf /tmp/ospf-mdr

echo "==> Cleaning up..."
rm coreemu.deb

# =========================================
# Scenario Autostart Configuration
# =========================================

echo "==> Creating scenario autostart configuration..."

# Create desktop config file for the user to specify a scenario
mkdir -p /root/Desktop
cat > /root/Desktop/autostart.conf << 'AUTOSTART_CONF'
# CoreEMU Scenario Autostart Configuration
# -----------------------------------------
# To automatically load a scenario on boot, uncomment the line below
# and set the path to your .xml scenario file.
#
# SCENARIO_FILE="/root/myscenario.xml"
AUTOSTART_CONF

# Create the autostart wrapper script
cat > /usr/local/bin/core-autostart << 'AUTOSTART_SCRIPT'
#!/bin/bash
# core-autostart: Reads /root/Desktop/autostart.conf and starts a scenario if configured.

CONF_FILE="/root/Desktop/autostart.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "core-autostart: No config file found at $CONF_FILE, skipping."
    exit 0
fi

source "$CONF_FILE"

if [ -z "$SCENARIO_FILE" ]; then
    echo "core-autostart: No SCENARIO_FILE configured, skipping."
    exit 0
fi

if [ ! -f "$SCENARIO_FILE" ]; then
    echo "core-autostart: Scenario file not found: $SCENARIO_FILE"
    exit 1
fi

echo "core-autostart: Loading scenario $SCENARIO_FILE..."
sleep 5  # Give core-daemon a moment to fully initialize gRPC

# Use core-cli to load and start the scenario
if command -v core-cli &> /dev/null; then
    core-cli xml -f "$SCENARIO_FILE" -s
else
    echo "core-autostart: core-cli not found in PATH."
    exit 1
fi
AUTOSTART_SCRIPT
chmod +x /usr/local/bin/core-autostart

# Create the systemd service
cat > /etc/systemd/system/core-autostart.service << 'SYSTEMD_SERVICE'
[Unit]
Description=CoreEMU Scenario Autostart
After=core-daemon.service
Requires=core-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/core-autostart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

systemctl daemon-reload
systemctl enable core-autostart.service

echo "========================================="
echo "   Setup Complete!                       "
echo "========================================="
echo "- Docker is installed and running."
echo "- Basic CLI IDE tools (vim, nano) are installed."
echo "- CoreEMU backend (core-daemon) is enabled and running."
echo "- Scenario autostart is configured via /root/Desktop/autostart.conf"
echo ""
echo "Verify status with:"
echo "  systemctl status core-daemon"
echo "  docker ps"

echo ""
read -p "Would you like to reboot the system now? (y/N): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Rebooting system..."
    reboot
else
    echo "Please remember to reboot the system manually to apply all changes."
fi
