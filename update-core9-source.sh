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

echo "==> Compiling protobuf/gRPC stubs..."
REPO_ROOT="/tmp/core-source"
PROTO_ROOT="$REPO_ROOT/daemon/proto"
PROTO_FILES="$PROTO_ROOT/core/api/grpc"

if [ -d "$PROTO_FILES" ]; then
    "$CORE_VENV/bin/python" -m grpc_tools.protoc \
        --proto_path="$PROTO_ROOT" \
        --python_out="$REPO_ROOT/daemon" \
        --grpc_python_out="$REPO_ROOT/daemon" \
        "$PROTO_FILES"/*.proto
    echo "    Compiled $(ls "$PROTO_FILES"/*.proto | wc -l) proto files."
else
    echo "    WARNING: No proto files found at $PROTO_FILES, skipping stub generation."
fi

echo "==> Overlaying updated source into CoreEMU venv..."
SITE_PACKAGES="$CORE_VENV/lib/python3.11/site-packages"
if [ ! -d "$SITE_PACKAGES" ]; then
    SITE_PACKAGES=$("$CORE_VENV/bin/python" -c "import site; print(site.getsitepackages()[0])")
fi
INSTALLED_CORE="$SITE_PACKAGES/core"
SOURCE_CORE="$REPO_ROOT/daemon/core"

# Back up generated/build-configured files (e.g. constants.py from constants.py.in).
# These exist in the installed package but NOT in the raw source. Without this backup,
# cp -r would delete them since the source directory replaces the destination.
BACKUP_DIR="/tmp/core-generated-backup"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
echo "    Backing up generated files..."
BACKUP_COUNT=0
cd "$INSTALLED_CORE"
find . -name "*.py" -o -name "*.so" -o -name "*.pyc" | while read f; do
    if [ ! -f "$SOURCE_CORE/$f" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$f")"
        cp "$f" "$BACKUP_DIR/$f"
    fi
done
BACKUP_COUNT=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
echo "    Backed up $BACKUP_COUNT generated files."

# Copy source files over the installation
cp -r "$SOURCE_CORE" "$SITE_PACKAGES/"

# Restore generated files
cp -a "$BACKUP_DIR/." "$INSTALLED_CORE/"
echo "    Restored generated files."
rm -rf "$BACKUP_DIR"
echo "    Updated $INSTALLED_CORE"

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
