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
apt-get install -y sudo curl wget jq git vim nano htop net-tools build-essential ca-certificates software-properties-common tcpdump tshark python-is-python3 python3-dev python3-venv python3-pip python3.9-venv python3-tk python3-setuptools python3-wheel libtool gawk libreadline-dev automake pkg-config libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libev-dev

echo "==> Installing minimal graphical environment (XFCE)..."
apt-get install -y xorg xfce4 lightdm dbus-x11 x11-utils xterm



echo "==> Compiling CoreEMU 8.2.0 from source (required for legacy GUI)..."
cd /tmp
rm -rf /tmp/core
git clone https://github.com/coreemu/core.git
cd core
git checkout release-8.2.0

echo "==> Patching CoreEMU dependencies for Python 3.9 compatibility..."
# grpcio 1.27.2 lacks Python 3.9 wheels and fails to compile from source. 
# We pin exactly to 1.43.0 because broad constraints (>=) cause the poetry 1.1.12 resolver to hang indefinitely.
sed -i 's/grpcio = "1.27.2"/grpcio = "1.43.0"/g' daemon/pyproject.toml
sed -i 's/grpcio-tools = "1.27.2"/grpcio-tools = "1.43.0"/g' daemon/pyproject.toml
sed -i 's/grpcio==1.27.2/grpcio==1.43.0/g' tasks.py
sed -i 's/grpcio-tools==1.27.2/grpcio-tools==1.43.0/g' tasks.py

# Upgrade other C-extension packages that lack Python 3.9 wheels to avoid source compilation errors
sed -i 's/pyproj = "2.6.1.post1"/pyproj = "3.2.0"/g' daemon/pyproject.toml
sed -i 's/lxml = "4.6.5"/lxml = "4.9.0"/g' daemon/pyproject.toml

sed -i 's/requires = \["poetry>=0.12"\]/requires = ["poetry>=0.12", "setuptools"]/g' daemon/pyproject.toml
rm -f daemon/poetry.lock

echo "==> Running CoreEMU 8.2.0 setup toolchain..."
# Clean up existing pipx environments to prevent "already installed" crashes
rm -rf ~/.local/pipx ~/.local/bin/invoke ~/.local/bin/poetry

echo "==> Removing any existing core installations to prevent setup script crashes..."
python3 -m pip uninstall -y core >/dev/null 2>&1 || true
rm -f /usr/local/bin/core-* /usr/bin/core-*

./setup.sh

echo "==> Injecting setuptools into Poetry to fix pkg_resources errors..."
export PATH="$HOME/.local/bin:$PATH"
pipx inject poetry setuptools

echo "==> Running Invoke installation (verbose mode)..."
export PATH="$HOME/.local/bin:$PATH"
# We pass --local to force a system-wide install via pip, completely bypassing Poetry's infinitely hanging resolver.
# We pass --no-ospf because we compile OSPF-MDR ourselves at the bottom of this script with the correct -fcommon flags.
inv install -v -i debian --local --no-ospf

echo "==> Installing CoreEMU runtime Python dependencies..."
# The --local flag only installs the core wheel itself without its dependencies.
CORE_DEPS="grpcio==1.43.0 grpcio-tools==1.43.0 fabric==2.5.0 invoke==1.4.1 lxml==4.9.0 mako==1.1.3 netaddr==0.7.19 pillow==8.3.2 protobuf==3.19.4 pyproj==3.2.0 pyyaml==5.4 setuptools"

# Install to the SYSTEM site-packages so ALL users (not just root) can use core-gui.
# Without --target, pip as root may install to ~/.local which is only visible to root.
SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])")
echo "==> Installing to system site-packages: $SITE_PACKAGES"
python3 -m pip install --target="$SITE_PACKAGES" $CORE_DEPS

echo "==> Enabling and starting core-daemon..."
systemctl daemon-reload
systemctl enable core-daemon
systemctl restart core-daemon

echo "==> Configuring CoreEMU Autostart Service..."
mkdir -p /etc/core
cat << 'EOF' > /etc/core/autostart.conf
# CoreEMU Autostart Configuration
# To run a scenario automatically on boot, uncomment the line below and specify the absolute path to your scenario file (.imn or .xml).
# SCENARIO_FILE="/root/myscenario.imn"
EOF
chmod 644 /etc/core/autostart.conf

cat << 'EOF' > /usr/local/bin/core-autostart
#!/bin/bash
# core-autostart: Waits for core-daemon + gRPC to be fully ready, then starts a scenario.

CONFIG_FILE="/etc/core/autostart.conf"
MAX_WAIT=60       # Maximum seconds to wait for core-daemon
GRPC_PORT=50051   # Default core-daemon gRPC port

if [ ! -f "$CONFIG_FILE" ]; then
    echo "core-autostart: No config file found at $CONFIG_FILE, skipping."
    exit 0
fi

source "$CONFIG_FILE"

if [ -z "$SCENARIO_FILE" ]; then
    echo "core-autostart: No SCENARIO_FILE configured, skipping."
    exit 0
fi

if [ ! -f "$SCENARIO_FILE" ]; then
    echo "core-autostart: ERROR - Scenario file not found: $SCENARIO_FILE"
    exit 1
fi

# --- Wait for core-daemon systemd service ---
echo "core-autostart: Waiting for core-daemon service to be active..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if systemctl is-active --quiet core-daemon; then
        echo "core-autostart: core-daemon service is active."
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if ! systemctl is-active --quiet core-daemon; then
    echo "core-autostart: ERROR - core-daemon did not start within ${MAX_WAIT}s."
    exit 1
fi

# --- Wait for gRPC port to be listening ---
echo "core-autostart: Waiting for gRPC port $GRPC_PORT to be ready..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if ss -tlnp | grep -q ":${GRPC_PORT} "; then
        echo "core-autostart: gRPC port $GRPC_PORT is listening."
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if ! ss -tlnp | grep -q ":${GRPC_PORT} "; then
    echo "core-autostart: ERROR - gRPC port $GRPC_PORT not ready within ${MAX_WAIT}s."
    exit 1
fi

# --- Extra safety buffer for internal initialization ---
sleep 3

echo "core-autostart: Starting scenario: $SCENARIO_FILE"
core-gui-legacy -b "$SCENARIO_FILE"
echo "core-autostart: Scenario loaded successfully."
EOF
chmod +x /usr/local/bin/core-autostart

cat << 'EOF' > /etc/systemd/system/core-autostart.service
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
EOF

systemctl daemon-reload
systemctl enable core-autostart

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

# =========================================
# Regular (non-root) User Setup
# =========================================
echo "==> Configuring CoreEMU for regular users..."

# Detect the first non-root human user (UID >= 1000)
REGULAR_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
if [ -n "$REGULAR_USER" ]; then
    echo "==> Detected regular user: $REGULAR_USER"
    # Install the core wheel for the regular user so core-gui works under their account
    sudo -u "$REGULAR_USER" python3 -m pip install --user core 2>/dev/null || true
else
    echo "==> No regular user detected, skipping user-level setup."
fi

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

echo ""
read -p "Would you like to reboot the system now? (y/N): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Rebooting system..."
    reboot
else
    echo "Please remember to reboot the system manually to apply all changes."
fi
