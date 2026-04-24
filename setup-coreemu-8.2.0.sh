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
apt-get install -y sudo curl wget jq git vim nano htop build-essential ca-certificates software-properties-common tcpdump tshark python-is-python3 python3-dev python3-venv python3-pip python3.9-venv python3-tk python3-setuptools python3-wheel libtool gawk libreadline-dev automake pkg-config libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev libev-dev

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
sed -i 's/requires = \["poetry>=0.12"\]/requires = ["poetry>=0.12", "setuptools"]/g' daemon/pyproject.toml
rm -f daemon/poetry.lock

echo "==> Running CoreEMU 8.2.0 setup toolchain..."
# Clean up existing pipx environments to prevent "already installed" crashes
rm -rf ~/.local/pipx ~/.local/bin/invoke ~/.local/bin/poetry
./setup.sh

echo "==> Injecting setuptools into Poetry to fix pkg_resources errors..."
export PATH="$HOME/.local/bin:$PATH"
pipx inject poetry setuptools

echo "==> Running Invoke installation (verbose mode)..."
export PATH="$HOME/.local/bin:$PATH"
# We pass --local to force a system-wide install via pip, completely bypassing Poetry's infinitely hanging resolver.
inv install -v -i debian --local

echo "==> Enabling and starting core-daemon..."
systemctl daemon-reload
systemctl enable core-daemon
systemctl restart core-daemon

echo "==> Configuring CoreEMU Autostart Service..."
mkdir -p /root/Desktop
cat << 'EOF' > /root/Desktop/autostart.conf
# CoreEMU Autostart Configuration
# To run a scenario automatically on boot, uncomment the line below and specify the absolute path to your scenario file (.imn or .xml).
# SCENARIO_FILE="/root/myscenario.imn"
EOF
chmod 644 /root/Desktop/autostart.conf

cat << 'EOF' > /usr/local/bin/core-autostart
#!/bin/bash
CONFIG_FILE="/root/Desktop/autostart.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$SCENARIO_FILE" ]; then
        if [ -f "$SCENARIO_FILE" ]; then
            echo "Autostarting CoreEMU scenario: $SCENARIO_FILE"
            if command -v core-gui-legacy &> /dev/null; then
                core-gui-legacy -b "$SCENARIO_FILE"
            elif command -v core-gui &> /dev/null; then
                core-gui -b "$SCENARIO_FILE"
            else
                echo "Error: core-gui not found."
            fi
        else
            echo "Error: Scenario file $SCENARIO_FILE not found."
        fi
    fi
fi
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

echo ""
read -p "Would you like to reboot the system now? (y/N): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Rebooting system..."
    reboot
else
    echo "Please remember to reboot the system manually to apply all changes."
fi
