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

# Make sbin PATH available to ALL users (root + regular) on login
cat > /etc/profile.d/sbin-path.sh << 'EOF'
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
EOF
chmod 644 /etc/profile.d/sbin-path.sh

# Also add to /etc/bash.bashrc for non-login shells (e.g., XFCE terminal windows)
if ! grep -q '/usr/sbin' /etc/bash.bashrc 2>/dev/null; then
    echo 'export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"' >> /etc/bash.bashrc
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating system packages..."
apt-get update
apt-get upgrade -y

echo "==> Installing basic CLI tools, dependencies, and network daemons..."
apt-get install -y sudo curl wget jq git vim nano htop net-tools build-essential ca-certificates software-properties-common tcpdump tshark python-is-python3 python3-full python3-venv python3-pip python3.11-venv python3-tk libtool gawk libreadline-dev automake pkg-config

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
    echo "==> Docker is already installed, skipping installation."
fi

# =========================================
# CoreEMU Installation
# =========================================

FROM_SOURCE=false
CORE_ARG1=""
CORE_ARG2=""

# Parse arguments: detect --from-source flag
for arg in "$@"; do
    if [ "$arg" = "--from-source" ]; then
        FROM_SOURCE=true
    elif [ -z "$CORE_ARG1" ]; then
        CORE_ARG1="$arg"
    elif [ -z "$CORE_ARG2" ]; then
        CORE_ARG2="$arg"
    fi
done

if [ "$FROM_SOURCE" = true ]; then
    # =========================================
    # Source-based installation (for developers)
    # =========================================
    CORE_REPO="${CORE_ARG1:-https://github.com/coreemu/core.git}"
    CORE_BRANCH="${CORE_ARG2:-release-9.2.1}"
    CORE_SOURCE_DIR="/opt/core/source"
    CORE_VENV="/opt/core/venv"

    echo "==> Installing CoreEMU from source ($CORE_REPO @ $CORE_BRANCH)..."

    # Clone or update the source
    if [ -d "$CORE_SOURCE_DIR/.git" ]; then
        echo "    Source directory exists, pulling latest..."
        cd "$CORE_SOURCE_DIR"
        git fetch --all
        git checkout "$CORE_BRANCH"
        git pull origin "$CORE_BRANCH" || true
    else
        echo "    Cloning repository..."
        rm -rf "$CORE_SOURCE_DIR"
        mkdir -p /opt/core
        git clone "$CORE_REPO" "$CORE_SOURCE_DIR"
        cd "$CORE_SOURCE_DIR"
        git checkout "$CORE_BRANCH"
    fi

    # Create venv
    echo "==> Creating virtual environment at $CORE_VENV..."
    python3 -m venv "$CORE_VENV"

    # Install dependencies from pyproject.toml
    echo "==> Installing Python dependencies..."
    "$CORE_VENV/bin/pip" install --upgrade pip
    "$CORE_VENV/bin/pip" install \
        "fabric==3.2.2" "grpcio==1.69.0" "invoke==2.2.0" "lxml==5.2.2" \
        "netaddr==0.10.1" "protobuf==5.29.3" "pyproj==3.6.1" "Mako==1.2.3" \
        "PyYAML==6.0.1" "pillow==11.1.0" "grpcio-tools==1.69.0"

    # Generate constants.py from template
    echo "==> Generating constants.py..."
    CONSTANTS_TEMPLATE="$CORE_SOURCE_DIR/daemon/core/constants.py.in"
    if [ -f "$CONSTANTS_TEMPLATE" ]; then
        CORE_VERSION=$(grep 'version' "$CORE_SOURCE_DIR/daemon/pyproject.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
        sed \
            -e "s|@PACKAGE_VERSION@|$CORE_VERSION|g" \
            -e "s|@CORE_CONF_DIR@|/etc/core|g" \
            -e "s|@CORE_DATA_DIR@|/opt/core/share|g" \
            "$CONSTANTS_TEMPLATE" > "$CORE_SOURCE_DIR/daemon/core/constants.py"
        echo "    Generated constants.py (version=$CORE_VERSION)"
    fi

    # Compile protobuf stubs
    echo "==> Compiling protobuf/gRPC stubs..."
    PROTO_ROOT="$CORE_SOURCE_DIR/daemon/proto"
    PROTO_FILES="$PROTO_ROOT/core/api/grpc"
    if [ -d "$PROTO_FILES" ]; then
        "$CORE_VENV/bin/python" -m grpc_tools.protoc \
            --proto_path="$PROTO_ROOT" \
            --python_out="$CORE_SOURCE_DIR/daemon" \
            --grpc_python_out="$CORE_SOURCE_DIR/daemon" \
            "$PROTO_FILES"/*.proto
        echo "    Compiled $(ls "$PROTO_FILES"/*.proto | wc -l) proto files."
    fi

    # Install core package
    echo "==> Installing core daemon into venv..."
    cd "$CORE_SOURCE_DIR/daemon"
    "$CORE_VENV/bin/pip" install .

    # Poetry excludes git-ignored generated files when building the wheel for pip.
    # We must manually copy them into the venv's site-packages.
    SITE_PACKAGES=$("$CORE_VENV/bin/python" -c "import site; print(site.getsitepackages()[0])")
    echo "==> Copying generated artifacts to $SITE_PACKAGES/core/ ..."
    cp "$CORE_SOURCE_DIR/daemon/core/constants.py" "$SITE_PACKAGES/core/"
    cp "$PROTO_FILES"/*_pb2*.py "$SITE_PACKAGES/core/api/grpc/"

    # Create symlinks for CLI tools
    echo "==> Creating CLI symlinks..."
    for cmd in core-daemon core-cli core-gui core-player core-route-monitor core-service-update core-cleanup; do
        if [ -f "$CORE_VENV/bin/$cmd" ]; then
            ln -sf "$CORE_VENV/bin/$cmd" "/usr/bin/$cmd"
        fi
    done

    # Copy data files (GUI assets, default services, etc.)
    echo "==> Installing data files..."
    mkdir -p /opt/core/share
    if [ -d "$CORE_SOURCE_DIR/daemon/data" ]; then
        cp -r "$CORE_SOURCE_DIR/daemon/data/"* /opt/core/share/ 2>/dev/null || true
    fi

    # Create systemd service for core-daemon
    echo "==> Configuring core-daemon systemd service..."
    cat > /etc/systemd/system/core-daemon.service << 'DAEMON_SERVICE'
[Unit]
Description=CORE Daemon
After=network.target

[Service]
Type=simple
ExecStart=/opt/core/venv/bin/core-daemon
TasksMax=infinity

[Install]
WantedBy=multi-user.target
DAEMON_SERVICE

else
    # =========================================
    # .deb-based installation (default)
    # =========================================
    echo "==> Fetching CoreEMU release..."
    CORE_URL="$CORE_ARG1"

    if [ -z "$CORE_URL" ]; then
        echo "No URL provided, fetching latest release from GitHub..."
        CORE_URL=$(curl -s https://api.github.com/repos/coreemu/core/releases/latest | jq -r '.assets[] | select(.name | endswith("_amd64.deb") and (contains("distributed") | not)) | .browser_download_url' | head -n 1)

        if [ -z "$CORE_URL" ] || [ "$CORE_URL" = "null" ]; then
            echo "Warning: Failed to fetch the latest release URL from GitHub."
            echo "Defaulting to CoreEMU 9.2.1."
            CORE_URL="https://github.com/coreemu/core/releases/download/release-9.2.1/core_9.2.1_amd64.deb"
        fi
    else
        echo "Using user-specified CoreEMU URL: $CORE_URL"
    fi

    echo "==> Downloading CoreEMU from $CORE_URL"
    wget -qO coreemu.deb "$CORE_URL"

    echo "==> Installing CoreEMU and system dependencies..."
    apt-get install -y ./coreemu.deb

    echo "==> Cleaning up..."
    rm coreemu.deb
fi

# =========================================
# Common post-install steps (both .deb and source)
# =========================================

echo "==> Compiling and Installing OSPF-MDR (Zebra)..."
if [ -f "/usr/local/sbin/zebra" ]; then
    echo "OSPF-MDR (Zebra) is already installed, skipping compilation."
else
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
fi

echo "==> Enabling and starting core-daemon..."
systemctl daemon-reload
systemctl enable core-daemon
systemctl restart core-daemon

# =========================================
# Scenario Autostart Configuration
# =========================================

echo "==> Creating scenario autostart configuration..."

# Create system-wide config file for the user to specify a scenario
mkdir -p /etc/core
cat > /etc/core/autostart.conf << 'AUTOSTART_CONF'
# CoreEMU Scenario Autostart Configuration
# -----------------------------------------
# To automatically load a scenario on boot, uncomment the line below
# and set the path to your .xml scenario file.
#
# SCENARIO_FILE="/root/myscenario.xml"
AUTOSTART_CONF
chmod 644 /etc/core/autostart.conf

# Create the autostart wrapper script
cat > /usr/local/bin/core-autostart << 'AUTOSTART_SCRIPT'
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
core-cli xml -f "$SCENARIO_FILE" -s
echo "core-autostart: Scenario loaded successfully."
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
