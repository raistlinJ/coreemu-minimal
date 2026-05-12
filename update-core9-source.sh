#!/bin/bash
# update-core9-source.sh
# Update a source-based CoreEMU 9.x installation.
# Requires that CoreEMU was initially installed with: setup-coreemu9.2.1.sh --from-source

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or log in as root."
  exit 1
fi

CORE_SOURCE_DIR="/opt/core/source"
CORE_VENV="/opt/core/venv"

# Verify source-based installation exists
if [ ! -d "$CORE_SOURCE_DIR/.git" ]; then
    echo "ERROR: No source installation found at $CORE_SOURCE_DIR"
    echo "This script requires CoreEMU to have been installed with:"
    echo "  ./setup-coreemu9.2.1.sh --from-source [REPO_URL] [BRANCH]"
    exit 1
fi

if [ ! -d "$CORE_VENV" ]; then
    echo "ERROR: CoreEMU venv not found at $CORE_VENV"
    exit 1
fi

echo "==> Ensuring core-daemon is stopped..."
if systemctl is-active --quiet core-daemon; then
    systemctl stop core-daemon
    echo "    core-daemon stopped."
else
    echo "    core-daemon is already stopped."
fi

echo "==> Pulling latest changes..."
cd "$CORE_SOURCE_DIR"
git pull
echo "    Updated to $(git log --oneline -1)"

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

# Reinstall core package
echo "==> Reinstalling core daemon..."
cd "$CORE_SOURCE_DIR/daemon"
"$CORE_VENV/bin/pip" install .

# Poetry excludes git-ignored generated files when building the wheel for pip.
# We must manually copy them into the venv's site-packages.
SITE_PACKAGES=$("$CORE_VENV/bin/python" -c "import site; print(site.getsitepackages()[0])")
echo "==> Copying generated artifacts to $SITE_PACKAGES/core/ ..."
cp "$CORE_SOURCE_DIR/daemon/core/constants.py" "$SITE_PACKAGES/core/"
cp "$CORE_SOURCE_DIR/daemon/core/api/grpc/"*_pb2*.py "$SITE_PACKAGES/core/api/grpc/"

echo "==> Success! CoreEMU has been updated."
echo ""
read -p "Would you like to start core-daemon now? (y/N): " START_CHOICE
if [[ "$START_CHOICE" =~ ^[Yy]$ ]]; then
    systemctl start core-daemon
    echo "core-daemon started."
else
    echo "core-daemon is stopped. Start it manually with: systemctl start core-daemon"
fi
