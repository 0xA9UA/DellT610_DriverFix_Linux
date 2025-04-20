# DriverFix_t610

A one‑stop, idempotent shell script to restore reliable VM networking on a Dell PowerEdge T610 running Debian 11/12. It:

- Installs Broadcom `bnx2` firmware if missing  
- Disables problematic NIC off‑loads (GRO/GSO/TSO/etc.) and persists the change  
- Defines, autostarts and starts libvirt’s default NAT (`virbr0`) network  
- Cleans up stray `default dev vnet*` routes and prevents them (NetworkManager, systemd‑networkd, or Avahi)  
- Enables IPv4 forwarding (immediate + persistent)

## Requirements

- Debian 11 or 12 (bookworm)  
- `bash`, `ip`, `ethtool`, `brctl`, `virsh`, `systemctl`  
- Root or `sudo` privileges  

## Usage

1. Clone or download this repo.  
2. Make the script executable:

   ```bash
   chmod +x fix_vm_net_t610.sh
Run as root (optionally specify your uplink interface):

bash
Copy
Edit
sudo ./fix_vm_net_t610.sh [eno1]
Reboot once and verify your KVM or VirtualBox guests can reach the Internet.
