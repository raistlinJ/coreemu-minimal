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

echo "==> Installing CoreEMU Python daemon from source..."
cd daemon
# On Debian 12+, we need --break-system-packages to override the system-managed python protection.
# Since CoreEMU daemon runs as a system service, this is the appropriate way to update it.
python3 -m pip install . --break-system-packages

echo "==> Restarting core-daemon service..."
systemctl restart core-daemon

echo "==> Success! CoreEMU has been updated from source."
echo "Note: This updated the Python daemon and CLI. If you modified C-based binaries (vcmd/vnoded), you may still need a full rebuild."
