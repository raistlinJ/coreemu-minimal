#!/bin/bash
# cleanup.sh
# Utility script to clean up cached build directories if an installation fails mid-way.

echo "==> Cleaning up CoreEMU temporary build directories..."

if [ -d "/tmp/core" ]; then
    echo "Removing /tmp/core..."
    rm -rf /tmp/core
fi

if [ -d "/tmp/ospf-mdr" ]; then
    echo "Removing /tmp/ospf-mdr..."
    rm -rf /tmp/ospf-mdr
fi

if [ -f "/tmp/coreemu.deb" ]; then
    echo "Removing /tmp/coreemu.deb..."
    rm -f /tmp/coreemu.deb
fi

if [ -d "$HOME/.local/pipx" ] || [ -f "$HOME/.local/bin/invoke" ]; then
    echo "Removing cached pipx environments (invoke/poetry)..."
    rm -rf ~/.local/pipx ~/.local/bin/invoke ~/.local/bin/poetry
fi

echo "Removing previously installed core python modules and scripts..."
python3 -m pip uninstall -y core >/dev/null 2>&1 || true
rm -f /usr/local/bin/core-* /usr/bin/core-*

echo "==> Cleanup complete. You can now re-run the setup scripts from a clean state."
