# CoreEMU Minimal

Automated deployment scripts for provisioning lightweight, production-ready CoreEMU environments on minimal Debian machines. Supports both the latest release (9.2.1 on Debian 12) and the legacy version (8.2.0 on Debian 11).

## Features

- **Lightweight OS Base**: Designed specifically for the Debian "netinst" minimal ISOs (no desktop pre-installed).
- **Full Source Compilation (8.2.0)**: Compiles CoreEMU 8.2.0 and all dependencies from source with automatic patching for Python 3.9 compatibility.
- **Docker Integration (9.2.1)**: Automatically installs the Docker Engine and injects the `{"iptables": false}` fix so Docker does not break CoreEMU's internal routing.
- **Native Routing Engines**: Compiles and installs **OSPF-MDR** (the US Naval Research Laboratory's custom Quagga fork) from source to provide the native `zebra` and `ospfd` routing daemons that CoreEMU expects.
- **Minimal GUI**: Installs an extremely lightweight desktop environment (XFCE + LightDM) to run `core-gui` directly on the VM.
- **Service Persistence**: Automatically enables `core-daemon` via systemd so it starts on every boot.
- **Robust Scenario Autostart**: Includes a systemd-based autostart mechanism with active polling to guarantee `core-daemon` and its gRPC API are fully ready before loading a scenario. Configure via `/etc/core/autostart.conf`.
- **Idempotent & Re-runnable**: Scripts clean up cached build directories automatically so they can be safely re-run after a failure without manual intervention.
- **Cleanup Utility**: Includes `cleanup.sh` to manually wipe all build caches and previously installed components for a fresh start.

## System Requirements

For optimal performance and to ensure enough space for emulator artifacts, the following VM specifications are recommended:
- **RAM**: 2GB minimum (4GB+ recommended for large network topologies or Docker nodes).
- **Storage (HD)**: 15–20GB minimum (the OS, GUI, and CoreEMU take ~5GB; remaining space is for PCAPs, logs, and Docker images).
- **CPU**: 2 vCores minimum.

## Deployment — CoreEMU 9.2.1 (Debian 12)

1. **Create the Environment**: Create a VM (or bare metal) and install the minimal [Debian 12 "netinst" ISO](https://www.debian.org/releases/bookworm/debian-installer/). When the installer prompts for "Software selection", ensure only the following are checked:
   - `[ ]` Debian desktop environment *(UNCHECK)*
   - `[ ]` GNOME *(UNCHECK)*
   - `[*] ` **SSH server** *(CHECK)*
   - `[*] ` **standard system utilities** *(CHECK)*
2. **Download & Run**:
   ```bash
   su -
   apt update && apt install -y git
   git clone https://github.com/raistlinJ/coreemu-minimal.git
   cd coreemu-minimal
   ./setup-coreemu9.2.1.sh
   ```
3. **Reboot**: The script will prompt you to reboot when finished.
4. **Access GUI**: Log in via the LightDM graphical login screen, open a terminal, and run `core-gui`.

## Deployment — CoreEMU 8.2.0 (Debian 11)

If you require the legacy interface (`core-gui-legacy`) to manage custom services, you must use version 8.2.0. Because 8.2.0 relies on older dependencies, you **must use a Debian 11 (Bullseye)** machine.

> [!NOTE]
> CoreEMU 8.2.0 does not support Docker nodes. The legacy script does **not** install the Docker Engine.

1. **Create the Environment**: Create a minimal VM using the [**Debian 11** netinst ISO](https://www.debian.org/releases/bullseye/debian-installer/).
2. **Download & Run**:
   ```bash
   su -
   apt update && apt install -y git
   git clone https://github.com/raistlinJ/coreemu-minimal.git
   cd coreemu-minimal
   ./setup-coreemu-8.2.0.sh
   ```
3. **Reboot**: The script will prompt you to reboot when finished.
4. **Access GUI**: Log in via LightDM, open a terminal, and run `core-gui`.

## Scenario Autostart (Both Versions)

Both scripts install a systemd-based autostart mechanism that reliably loads a CoreEMU scenario on boot, replacing the old, unreliable `rc.local` approach.

### Boot Sequence

```
System Boot
  └─▶ systemd starts core-daemon.service
        └─▶ core-autostart.service triggers
              ├─ Polls systemctl until core-daemon is active (up to 60s)
              ├─ Polls gRPC port 50051 until it is listening (up to 60s)
              ├─ Waits 3s safety buffer
              └─▶ Loads scenario via core-gui-legacy -b (8.2.0) or core-cli xml -f -s (9.2.1)
```

### Configuration

1. Edit `/etc/core/autostart.conf` (accessible to all users):
   ```bash
   sudo nano /etc/core/autostart.conf
   ```
2. Uncomment the `SCENARIO_FILE` line and set the path to your topology file:
   ```bash
   SCENARIO_FILE="/root/myscenario.imn"
   ```
3. Reboot. The scenario will load automatically once `core-daemon` and gRPC are confirmed ready.

### Monitoring

Check the autostart service status and logs:
```bash
systemctl status core-autostart
journalctl -u core-autostart
```

> [!NOTE]
> On 9.2.1, scenarios are loaded via `core-cli xml -f <file> -s`. On 8.2.0, scenarios are loaded via `core-gui-legacy -b <file>`.

## Troubleshooting

If an installation fails mid-way and you need to start fresh, run the cleanup utility before re-running the setup script:
```bash
./cleanup.sh
```
This removes all cached build directories (`/tmp/core`, `/tmp/ospf-mdr`), previously installed `core` Python packages, and leftover `pipx` environments.
