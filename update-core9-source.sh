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
# Directly copy the core package into the venv's site-packages.
# This is more reliable than pip install, which builds a wheel that may
# exclude generated _pb2.py files. Direct copy preserves everything.
SITE_PACKAGES="$CORE_VENV/lib/python3.11/site-packages"
if [ ! -d "$SITE_PACKAGES" ]; then
    # Fallback: find the actual site-packages path
    SITE_PACKAGES=$("$CORE_VENV/bin/python" -c "import site; print(site.getsitepackages()[0])")
fi
cp -r "$REPO_ROOT/daemon/core" "$SITE_PACKAGES/"
echo "    Copied to $SITE_PACKAGES/core/"

echo "==> Cleaning up..."
rm -rf /tmp/core-source

echo "==> Restarting core-daemon service..."
systemctl restart core-daemon

echo "==> Success! CoreEMU has been updated from source."
echo "Note: This updated the Python daemon and CLI. If you modified C-based binaries (vcmd/vnoded), you may still need a full rebuild."
