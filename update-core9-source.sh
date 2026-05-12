#!/bin/bash
# update-core9-source.sh
# Efficiently update CoreEMU 9.2.1+ from a Git fork without rebuilding the .deb package.

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or log in as root."
  exit 1
fi

REPO_URL="${1}"
BRANCH="${2:-master}"

if [ -z "$REPO_URL" ]; then
    echo "Usage: ./update-core9-source.sh <REPO_URL> [BRANCH]"
    echo "Example: ./update-core9-source.sh https://github.com/youruser/core.git my-fix-branch"
    exit 1
fi

echo "==> Ensuring core-daemon is stopped..."
if systemctl is-active --quiet core-daemon; then
    systemctl stop core-daemon
    echo "    core-daemon stopped."
else
    echo "    core-daemon is already stopped."
fi

echo "==> Cloning $REPO_URL ($BRANCH)..."
rm -rf /tmp/core-source
git clone "$REPO_URL" /tmp/core-source
cd /tmp/core-source
git checkout "$BRANCH"

echo "==> Detecting CoreEMU virtual environment..."
# The .deb package installs CoreEMU into its own venv with all dependencies (grpcio, netaddr, etc.).
# We must install into THAT venv so our updated code can find them.
CORE_VENV="/opt/core/venv"
if [ ! -d "$CORE_VENV" ]; then
    echo "ERROR: CoreEMU venv not found at $CORE_VENV"
    echo "Make sure CoreEMU was initially installed via the .deb package (setup-coreemu9.2.1.sh)."
    exit 1
fi

echo "==> Installing build tools..."
"$CORE_VENV/bin/pip" install grpcio-tools

echo "==> Generating build artifacts..."
REPO_ROOT="/tmp/core-source"
SOURCE_CORE="$REPO_ROOT/daemon/core"

# 1. Generate constants.py from constants.py.in template
#    The source only has constants.py.in with placeholders like @PACKAGE_VERSION@.
#    The .deb build fills these in. We do it here with the installed values.
CONSTANTS_TEMPLATE="$SOURCE_CORE/constants.py.in"
if [ -f "$CONSTANTS_TEMPLATE" ]; then
    echo "    Generating constants.py from template..."
    CORE_VERSION=$(cat "$REPO_ROOT/package.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','9.2.1'))" 2>/dev/null || echo "9.2.1")
    sed \
        -e "s|@PACKAGE_VERSION@|$CORE_VERSION|g" \
        -e "s|@CORE_CONF_DIR@|/etc/core|g" \
        -e "s|@CORE_DATA_DIR@|/opt/core/share|g" \
        "$CONSTANTS_TEMPLATE" > "$SOURCE_CORE/constants.py"
    echo "    Generated constants.py (version=$CORE_VERSION)"
fi

# 2. Compile protobuf/gRPC stubs (_pb2.py and _pb2_grpc.py)
PROTO_ROOT="$REPO_ROOT/daemon/proto"
PROTO_FILES="$PROTO_ROOT/core/api/grpc"
if [ -d "$PROTO_FILES" ]; then
    echo "    Compiling protobuf stubs..."
    "$CORE_VENV/bin/python" -m grpc_tools.protoc \
        --proto_path="$PROTO_ROOT" \
        --python_out="$REPO_ROOT/daemon" \
        --grpc_python_out="$REPO_ROOT/daemon" \
        "$PROTO_FILES"/*.proto
    echo "    Compiled $(ls "$PROTO_FILES"/*.proto | wc -l) proto files."
else
    echo "    WARNING: No proto files found, skipping stub generation."
fi

echo "==> Overlaying updated source into CoreEMU venv..."
SITE_PACKAGES="$CORE_VENV/lib/python3.11/site-packages"
if [ ! -d "$SITE_PACKAGES" ]; then
    SITE_PACKAGES=$("$CORE_VENV/bin/python" -c "import site; print(site.getsitepackages()[0])")
fi
cp -r "$SOURCE_CORE" "$SITE_PACKAGES/"
echo "    Updated $SITE_PACKAGES/core/"

echo "==> Cleaning up..."
rm -rf /tmp/core-source

echo "==> Success! CoreEMU has been updated from source."
echo "Note: This updated the Python daemon and CLI. If you modified C-based binaries (vcmd/vnoded), you may still need a full rebuild."
echo ""
read -p "Would you like to start core-daemon now? (y/N): " START_CHOICE
if [[ "$START_CHOICE" =~ ^[Yy]$ ]]; then
    systemctl start core-daemon
    echo "core-daemon started."
else
    echo "core-daemon is stopped. Start it manually with: systemctl start core-daemon"
fi
