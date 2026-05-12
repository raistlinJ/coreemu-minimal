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
cd daemon
# The _pb2.py and _pb2_grpc.py files are generated from .proto definitions.
# The .deb build process creates these, but they don't exist in raw source.
# We must compile them before installing.
PROTO_DIR="proto"
OUT_DIR="core/api/grpc"
if [ -d "$PROTO_DIR" ]; then
    "$CORE_VENV/bin/python" -m grpc_tools.protoc \
        -I "$PROTO_DIR" \
        --python_out="$OUT_DIR" \
        --grpc_python_out="$OUT_DIR" \
        "$PROTO_DIR"/*.proto
    echo "    Compiled $(ls "$PROTO_DIR"/*.proto | wc -l) proto files."
else
    echo "    WARNING: No proto directory found, skipping stub generation."
fi

echo "==> Installing CoreEMU Python daemon into $CORE_VENV..."
# Install into the .deb's venv where all dependencies already exist.
# --no-deps ensures we only overwrite CoreEMU code without touching the existing dependency tree.
"$CORE_VENV/bin/pip" install --no-deps .

echo "==> Cleaning up..."
rm -rf /tmp/core-source

echo "==> Restarting core-daemon service..."
systemctl restart core-daemon

echo "==> Success! CoreEMU has been updated from source."
echo "Note: This updated the Python daemon and CLI. If you modified C-based binaries (vcmd/vnoded), you may still need a full rebuild."
