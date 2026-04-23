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

echo "==> Cleanup complete. You can now re-run the setup scripts from a clean state."
