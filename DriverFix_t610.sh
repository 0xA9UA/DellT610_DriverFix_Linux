#!/usr/bin/env bash
#
# fix_vm_net_t610.sh
#
# A fully idempotent, check‑before‑you‑act script for Dell T610 on Debian:
# 1) Requires root
# 2) Installs Broadcom firmware‑bnx2 if missing
# 3) Disables NIC off‑load features if still enabled
# 4) Persists off‑load settings via systemd oneshot
# 5) Installs libvirt & brings up default NAT network only if necessary
# 6) Removes any stray default routes on vnet* taps
# 7) Configures NetworkManager or systemd-networkd to ignore vnet*
# 8) Enables IPv4 forwarding if not already enabled
#
# Usage: sudo ./fix_vm_net_t610.sh [uplink_interface]

set -euo pipefail
trap 'echo "Error on line $LINENO." >&2' ERR

# 0) Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

# 1) Detect uplink interface (or take first argument)
PHY_IF=${1:-$(ip -o -4 route get 1.1.1.1 | awk '{print $5; exit}')}
if [ -z "$PHY_IF" ]; then
  echo "Cannot detect uplink interface. Pass it as an argument." >&2
  exit 1
fi
echo "Uplink interface: $PHY_IF"

# Helper for Broadcom firmware check
need_fw() { dmesg | grep -qiE 'bnx2.*firmware.*failed to load'; }

# 2) Install firmware‑bnx2 if driver complained
if need_fw; then
  echo "-> Installing firmware-bnx2..."
  if ! grep -Rq non-free-firmware /etc/apt/sources.list*; then
    sed -Ei 's|^deb (\S+ bookworm main.*)|deb \1 contrib non-free non-free-firmware|' /etc/apt/sources.list
    echo "   enabled non-free-firmware repo"
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y firmware-bnx2
  echo "   firmware-bnx2 installed"
else
  echo "-> Broadcom firmware already present"
fi

# 3) Disable off‑loads if still enabled
disable_offload() {
  local dev=$1 changed=0
  for feature in gro gso tso sg rx tx; do
    if ethtool -k "$dev" | grep -qE "$feature: *on"; then
      ethtool -K "$dev" "$feature" off
      changed=1
    fi
  done
  return $changed
}

echo "-> Checking off‑loads on $PHY_IF..."
if disable_offload "$PHY_IF"; then
  echo "   disabled off‑loads on $PHY_IF"
else
  echo "   off‑loads already disabled on $PHY_IF"
fi

# Ensure bridge-utils for bridge detection
if ! command -v brctl &>/dev/null; then
  echo "-> Installing bridge-utils..."
  apt-get install -y bridge-utils
fi

# Detect primary bridge (virbr0 or first br* device)
BR=$( { brctl show 2>/dev/null || true; } | awk 'NR==2{print $1}')
if [ -z "$BR" ]; then
  BR=$(ip -br link | awk '$1 ~ /^br/ {print $1; exit}')
fi

if [ -n "$BR" ]; then
  echo "-> Checking off‑loads on bridge $BR..."
  if disable_offload "$BR"; then
    echo "   disabled off‑loads on $BR"
  else
    echo "   off‑loads already disabled on $BR"
  fi
else
  echo "-> No bridge detected; skipping bridge off‑load check"
fi

# 4) Persist off‑loads via systemd
SERVICE=/etc/systemd/system/disable-offload@.service
if [ ! -f "$SERVICE" ]; then
  echo "-> Creating systemd service to persist off‑loads"
  cat >"$SERVICE" <<'EOF'
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
else
  echo "-> Systemd service disable-offload@ already exists"
fi

echo "-> Enabling disable-offload@$PHY_IF.service"
systemctl enable "disable-offload@${PHY_IF}.service"
if [ -n "$BR" ]; then
  echo "-> Enabling disable-offload@$BR.service"
  systemctl enable "disable-offload@${BR}.service"
fi

# 5) Install libvirt and ensure default NAT network
if ! command -v virsh &>/dev/null; then
  echo "-> Installing libvirt packages..."
  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq-base
else
  echo "-> libvirt already installed"
fi

echo "-> Enabling and starting libvirtd"
if systemctl is-enabled libvirtd &>/dev/null; then
  echo "   libvirtd service already enabled"
else
  systemctl enable libvirtd
  echo "   libvirtd enabled"
fi
systemctl start libvirtd

# Define default NAT network if missing
if virsh net-list --all | grep -qw default; then
  echo "-> libvirt default network already defined"
else
  echo "-> Defining libvirt default network"
  virsh net-define /usr/share/libvirt/networks/default.xml
fi

# Autostart default network if not already
if virsh net-dumpxml default | grep -q '<autostart>yes</autostart>'; then
  echo "-> default network already set to autostart"
else
  echo "-> Enabling autostart for default network"
  virsh net-autostart default
fi

# Start default network if inactive
if virsh net-info default | grep -q 'Active:.*no'; then
  echo "-> Starting default network"
  virsh net-start default
else
  echo "-> default network already active"
fi

# 6) Remove any bogus default routes via vnet*
ROUTES=$(ip -4 route show default dev vnet* 2>/dev/null || true)
if [ -n "$ROUTES" ]; then
  echo "-> Removing stray default routes on vnet*"
  echo "$ROUTES" | awk '{print $3}' | xargs -r -n1 ip route del default dev
else
  echo "-> No default routes found on vnet*"
fi

# 7) Prevent future vnet* auto‑routes
if systemctl is-active --quiet NetworkManager; then
  NM_CONF=/etc/NetworkManager/conf.d/90-libvirt-vnet-ignore.conf
  if grep -q 'unmanaged-devices=interface-name:vnet*' "$NM_CONF" 2>/dev/null; then
    echo "-> NetworkManager already ignores vnet*"
  else
    echo "-> Configuring NetworkManager to ignore vnet*"
    mkdir -p /etc/NetworkManager/conf.d
    cat >"$NM_CONF" <<'EOF'
[keyfile]
unmanaged-devices=interface-name:vnet*
EOF
    systemctl reload NetworkManager
  fi
else
  LINK_FILE=/etc/systemd/network/99-libvirt-vnet.link
  if grep -q 'Unmanaged=yes' "$LINK_FILE" 2>/dev/null; then
    echo "-> systemd-networkd already ignores vnet*"
  else
    echo "-> Configuring systemd-networkd to ignore vnet*"
    mkdir -p "$(dirname "$LINK_FILE")"
    cat >"$LINK_FILE" <<'EOF'
[Match]
OriginalName=vnet*
[Link]
Unmanaged=yes
EOF
    systemctl restart systemd-networkd || true
  fi
fi

# 8) Enable IPv4 forwarding if not already
CURRENT=$(sysctl -n net.ipv4.ip_forward)
if [ "$CURRENT" -eq 1 ]; then
  echo "-> IPv4 forwarding already enabled"
else
  echo "-> Enabling IPv4 forwarding"
  sysctl -w net.ipv4.ip_forward=1
fi

if grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  echo "-> sysctl.conf already sets net.ipv4.ip_forward=1"
else
  echo "-> Persisting IPv4 forwarding in /etc/sysctl.conf"
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

echo "All steps complete. Please reboot once, then verify VM networking."
