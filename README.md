# CoreEMU Minimal

An automated deployment script for provisioning a lightweight, production-ready CoreEMU environment on a minimal Debian 12 machine. 

## Features

- **Lightweight OS Base**: Designed specifically for the Debian 12 "netinst" minimal ISO.
- **Docker Integration**: Automatically installs the Docker Engine and injects the `{"iptables": false}` fix into `/etc/docker/daemon.json` so Docker does not break CoreEMU's internal routing.
- **Dynamic Installer**: Dynamically queries the GitHub API to fetch and install the latest CoreEMU release.
- **Native Routing Engines**: Compiles and installs **OSPF-MDR** (the US Naval Research Laboratory's custom Quagga fork) from source to seamlessly provide the native `zebra` and `ospfd` routing engines that CoreEMU expects.
- **Minimal GUI**: Installs an extremely lightweight desktop environment (XFCE and LightDM) to run the `core-gui` IDE directly on the VM without bogging down resources.
- **Service Persistence**: Automatically enables the `core-daemon` systemd service so your emulator backend survives reboots.

## System Requirements

For optimal performance and to ensure enough space for emulator artifacts, the following VM specifications are recommended:
- **RAM**: 2GB minimum (4GB+ recommended if running heavy Docker nodes or large network topologies).
- **Storage (HD)**: 15GB to 20GB minimum (The OS, GUI, and CoreEMU take about ~5GB; the remaining space is necessary for PCAP files, logs, and Docker images).
- **CPU**: 2 vCores minimum.

## Deployment Instructions

1. **Create the Environment**: Create a VM (or bare metal environment) and install the minimal [Debian 12 "netinst" ISO](https://www.debian.org/releases/bookworm/debian-installer/). When the installer prompts you for "Software selection", ensure only the following are checked:
   - `[ ]` Debian desktop environment *(UNCHECK)*
   - `[ ]` GNOME *(UNCHECK)*
   - `[*] ` **SSH server** *(CHECK)*
   - `[*] ` **standard system utilities** *(CHECK)*
2. **Download Script**: Install Git, clone this repository to your VM, and navigate into it:
   ```bash
   su -
   apt update && apt install -y git
   git clone https://github.com/raistlinJ/coreemu-minimal.git
   cd coreemu-minimal
   ```
3. **Execute**: Run the script:
   ```bash
   ./setup-coreemu.sh
   ```
4. **Reboot**: Once finished, reboot the machine.
5. **Access GUI**: Access the machine's display console (e.g., hypervisor web console or physical monitor) to view the graphical LightDM login screen. Log in, open a terminal, and run `core-gui`.

## Legacy Version Support (CoreEMU 8.2.0)

If you require the legacy interface (`core-gui-legacy`) to fine-tune custom services, you must use version 8.2.0. Because 8.2.0 relies on older dependencies, you **must use a Debian 11 (Bullseye)** machine.

> [!NOTE]
> CoreEMU 8.2.0 does not natively support Docker nodes. As such, the legacy `setup-coreemu-8.2.0.sh` script does **not** install the Docker Engine.

To deploy the legacy version:
1. Create a minimal VM using the [**Debian 11** netinst ISO](https://www.debian.org/releases/bullseye/debian-installer/).
2. Download the repository and run the `setup-coreemu-8.2.0.sh` script instead of the default script:
   ```bash
   su -
   apt update && apt install -y git
   git clone https://github.com/raistlinJ/coreemu-minimal.git
   cd coreemu-minimal
   ./setup-coreemu-8.2.0.sh
   ```
