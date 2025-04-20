#!/usr/bin/env bash
#
# fix_vm_net_t610.sh
# A complete fix for Dell T610 on Debian: installs Broadcom firmware, disables
# NIC off‑loads that break VM networking, brings up libvirt default NAT, removes
# bogus vnet* default routes, and prevents future vnet* auto‑routes.
#
# Usage: sudo ./fix_vm_net_t610.sh [physical_interface]
# If no interface is passed, the script auto-detects the uplink via the default route.

set -euo pipefail
trap 'echo "Error on line $LINENO." >&2' ERR

# Detect the physical uplink interface (or use first script argument)
PHY_IF=${1:-$(ip -o -4 route get 1.1.1.1 | awk '{print $5; exit}')}
if [ -z "$PHY_IF" ]; then
  echo "No uplink interface detected. Pass it as an argument." >&2
  exit 1
fi

echo "Using uplink interface: $PHY_IF"

#
# 1) Ensure Broadcom NetXtreme II firmware (bnx2) is installed
#
# The BCM5709/5716 chip in the T610 requires a non-free firmware blob.
# If the driver logs “firmware failed to load,” install firmware-bnx2.
#
need_fw() {
  dmesg | grep -qiE "bnx2.*firmware.*failed to load"
}

if need_fw; then
  echo "Installing firmware-bnx2 from non-free-firmware repo..."
  # Enable non-free-firmware repository if not already enabled
  if ! grep -Rq non-free-firmware /etc/apt/sources.list*; then
    sed -Ei 's|^deb (\S+ bookworm main.*)|deb \1 contrib non-free non-free-firmware|' /etc/apt/sources.list
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y firmware-bnx2
else
  echo "Broadcom firmware already present."
fi

#
# 2) Disable hardware offloads that disrupt bridged/NAT traffic
#
# Offloads (GRO, GSO, TSO, scatter/gather, Rx/Tx checksumming) can cause
# packet corruption when traffic is bridged into VMs.
#
echo "Disabling NIC off‑loads on $PHY_IF..."
ethtool -K "$PHY_IF" gro off gso off tso off sg off rx off tx off

# Bridge-utils provides 'brctl' to list Linux bridges; install if missing
if ! command -v brctl &>/dev/null; then
  echo "Installing bridge-utils for bridge detection..."
  apt-get install -y bridge-utils
fi

# Detect the primary bridge (usually virbr0, or any 'br*' device)
BR=$( (brctl show 2>/dev/null || true) | awk 'NR==2{print $1}')
if [ -z "$BR" ]; then
  BR=$(ip -br link | awk '$1 ~ /^br/ {print $1; exit}')
fi

# If a bridge exists, disable offloads on it as well
if [ -n "$BR" ]; then
  echo "Disabling NIC off‑loads on bridge $BR..."
  ethtool -K "$BR" gro off gso off tso off sg off rx off tx off
fi

#
# 3) Persist offload settings via a systemd oneshot service
#
cat >/etc/systemd/system/disable-offload@.service <<'EOF'
[Unit]
Description=Disable NIC off‑loads on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K %i gro off gso off tso off sg off rx off tx off

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "disable-offload@${PHY_IF}.service"
[ -n "$BR" ] && systemctl enable "disable-offload@${BR}.service"

#
# 4) Install and activate libvirt's default NAT network (virbr0)
#
# Debian ships the XML but leaves it inactive by default.
#
if ! command -v virsh &>/dev/null; then
  echo "Installing libvirt and dependencies..."
  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq-base
fi

systemctl enable --now libvirtd

# Define the default network if it's not already known
if ! virsh net-info default &>/dev/null; then
  echo "Defining libvirt default network..."
  virsh net-define /usr/share/libvirt/networks/default.xml
fi

# Ensure the network starts on boot and is running now
virsh net-autostart default
virsh net-start default || true

#
# 5) Remove any bogus default routes via vnet* interfaces
#
# VMs create tap devices named vnet*, which can pick up a link-local
# address and pollute the host's default route table.
#
ip -4 route show default dev vnet* 2>/dev/null | awk '{print $3}' \
  | while read -r dev; do
      ip route del default dev "$dev" || true
    done

#
# 6) Prevent vnet* interfaces from being auto-managed in the future
#
# Depending on whether NetworkManager or systemd-networkd is in use:
#
if systemctl is-active --quiet NetworkManager; then
  # Tell NetworkManager to leave vnet* alone
  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/90-libvirt-vnet-ignore.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:vnet*
EOF
  systemctl reload NetworkManager
else
  # For systemd-networkd, ignore vnet* via a .link file
  mkdir -p /etc/systemd/network
  cat >/etc/systemd/network/99-libvirt-vnet.link <<EOF
[Match]
OriginalName=vnet*

[Link]
Unmanaged=yes
EOF
  systemctl restart systemd-networkd || true
fi

#
# 7) Ensure IPv4 forwarding is enabled for NAT to work
#
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf || \
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

echo "Driver fix complete. Please reboot, then start a VM to verify connectivity."
