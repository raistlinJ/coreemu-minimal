# CoreEMU Minimal

An automated deployment script for provisioning a lightweight, production-ready CoreEMU environment on a minimal Debian 12 Proxmox VM. 

## Features

- **Lightweight OS Base**: Designed specifically for the Debian 12 "netinst" minimal ISO.
- **Docker Integration**: Automatically installs the Docker Engine and injects the `{"iptables": false}` fix into `/etc/docker/daemon.json` so Docker does not break CoreEMU's internal routing.
- **Dynamic Installer**: Dynamically queries the GitHub API to fetch and install the latest CoreEMU release.
- **Routing Engines**: Installs FRR (Free Range Routing) to provide full `zebra`, `ospfd`, and `bgpd` support for complex network topologies.
- **Minimal GUI**: Installs an extremely lightweight desktop environment (XFCE and LightDM) to run the `core-gui` IDE directly on the VM without bogging down resources.
- **Service Persistence**: Automatically enables the `core-daemon` systemd service so your emulator backend survives reboots.

## Deployment Instructions

1. **Create the VM**: Create a VM in Proxmox and install the minimal Debian 12 "netinst" ISO. When the installer prompts you for "Software selection", ensure only the following are checked:
   - `[ ]` Debian desktop environment *(UNCHECK)*
   - `[ ]` GNOME *(UNCHECK)*
   - `[*] ` **SSH server** *(CHECK)*
   - `[*] ` **standard system utilities** *(CHECK)*
2. **Transfer Script**: Copy `setup-coreemu.sh` to your VM (e.g., via `scp`).
3. **Execute**: Run the script as root:
   ```bash
   sudo ./setup-coreemu.sh
   ```
4. **Reboot**: Once finished, reboot the VM.
5. **Access GUI**: Open the Proxmox "Console" for the VM to see the graphical LightDM login screen. Log in, open a terminal, and run `core-gui`.
