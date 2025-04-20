#!/usr/bin/env bash
#
# DriverFix_t610.sh
#
# Fully idempotent script for Dell PowerEdge T610 running Debian 11/12.
# It restores reliable VM networking for both KVM/libvirt and VirtualBox.
#
#  • Installs Broadcom bnx2 firmware if missing
#  • Disables NIC off‑load features that break bridged/NAT traffic
#  • Persists off‑loads via systemd oneshot template
#  • Ensures libvirt “default” NAT network is defined, autostarted, running
#  • Deletes stray `default dev vnet*` routes and prevents them permanently
#     – works for NetworkManager, systemd‑networkd, or Avahi‑autoipd cases
#  • Enables IPv4 forwarding (immediate + persistent)
#
# Usage:
#   sudo ./DriverFix_t610.sh [uplink_interface]
#   # interface auto-detected if omitted

set -euo pipefail
trap 'echo "ERROR on line $LINENO" >&2' ERR

###############################################################################
# 0) root guard
###############################################################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

###############################################################################
# 1) detect uplink interface
###############################################################################
PHY_IF=${1:-$(ip -o -4 route get 1.1.1.1 | awk '{print $5; exit}')}
[[ -n $PHY_IF ]] || { echo "Could not detect uplink; pass as arg." >&2; exit 1; }
echo "Uplink interface: $PHY_IF"

###############################################################################
# 2) Broadcom firmware check / install
###############################################################################
needs_fw() { dmesg | grep -qiE 'bnx2.*firmware.*failed to load'; }
if needs_fw; then
  echo "Installing firmware-bnx2…"
  if ! grep -Rq non-free-firmware /etc/apt/sources.list*; then
    sed -Ei 's|^deb (\S+ bookworm main.*)|deb \1 contrib non-free non-free-firmware|' /etc/apt/sources.list
    echo "  → enabled non-free-firmware repo"
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y firmware-bnx2
else
  echo "Broadcom firmware already present."
fi

###############################################################################
# 3) disable off‑loads (only if still on)
###############################################################################
offload_off() {
  local dev=$1 changed=0
  for f in gro gso tso sg rx tx; do
    if ethtool -k "$dev" | grep -qE "$f: +on"; then
      ethtool -K "$dev" "$f" off
      changed=1
    fi
  done
  return $changed
}

echo "Checking off‑loads on $PHY_IF…"
offload_off "$PHY_IF" && echo "  → disabled off‑loads on $PHY_IF" || echo "  → off‑loads already disabled"

# ensure bridge-utils present
command -v brctl >/dev/null || apt-get install -y bridge-utils

# detect bridge (virbr0 or br*)
BR=$(brctl show 2>/dev/null | awk 'NR==2{print $1}')
[[ -z $BR ]] && BR=$(ip -br link | awk '$1 ~ /^br/ {print $1; exit}')
if [[ -n $BR ]]; then
  echo "Checking off‑loads on bridge $BR…"
  offload_off "$BR" && echo "  → disabled off‑loads on $BR" || echo "  → off‑loads already disabled on $BR"
else
  echo "No Linux bridge detected."
fi

###############################################################################
# 4) persist off‑loads via systemd template
###############################################################################
SERVICE=/etc/systemd/system/disable-offload@.service
if [[ ! -f $SERVICE ]]; then
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
  echo "Created systemd off‑load template."
fi
systemctl enable "disable-offload@${PHY_IF}.service"
[[ -n $BR ]] && systemctl enable "disable-offload@${BR}.service"

###############################################################################
# 5) libvirt default NAT network
###############################################################################
if ! command -v virsh &>/dev/null; then
  echo "Installing libvirt packages…"
  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq-base
fi
systemctl enable --now libvirtd

if ! virsh net-list --all | grep -qw default; then
  echo "Defining libvirt default network…"
  virsh net-define /usr/share/libvirt/networks/default.xml
fi

if virsh net-dumpxml default | grep -q '<autostart>yes</autostart>'; then
  echo "libvirt default network already set to autostart."
else
  virsh net-autostart default
  echo "Enabled autostart for default network."
fi

if virsh net-info default | grep -q 'Active:.*no'; then
  virsh net-start default
  echo "Started libvirt default network."
else
  echo "libvirt default network already active."
fi

###############################################################################
# 6) remove stray default dev vnet* routes
###############################################################################
echo "Removing stray default routes on vnet* (if any)…"
for tap in $(ip -4 route | awk '/^default/ && / dev vnet/ {
                   for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)
                 }'); do
  echo "  → deleting default route via $tap"
  ip route del default dev "$tap" || true
done

###############################################################################
# 7) prevent future vnet* auto‑routes
###############################################################################
echo "Configuring system to ignore vnet* taps going forward…"

if systemctl is-active --quiet NetworkManager; then
  NM_CONF=/etc/NetworkManager/conf.d/90-libvirt-vnet-ignore.conf
  if ! grep -q 'unmanaged-devices=interface-name:vnet*' "$NM_CONF" 2>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat >"$NM_CONF" <<'EOF'
[keyfile]
unmanaged-devices=interface-name:vnet*
EOF
    systemctl reload NetworkManager
    echo "  → NetworkManager will ignore vnet*"
  else
    echo "  → NetworkManager already ignores vnet*"
  fi

elif systemctl is-active --quiet systemd-networkd; then
  LINK_FILE=/etc/systemd/network/99-libvirt-vnet.link
  if ! grep -q 'IPv4LL=no' "$LINK_FILE" 2>/dev/null; then
    mkdir -p /etc/systemd/network
    cat >"$LINK_FILE" <<'EOF'
[Match]
OriginalName=vnet*

[Link]
Unmanaged=yes
IPv4LL=no
EOF
    systemctl restart systemd-networkd
    echo "  → systemd-networkd set to ignore vnet* and disable IPv4LL"
  else
    echo "  → systemd-networkd already configured for vnet*"
  fi

else
  AVAHI_CONF=/etc/avahi/avahi-daemon.conf
  if ! grep -q '^deny-interfaces=vnet\*' "$AVAHI_CONF" 2>/dev/null; then
    sed -i '/^\[server\]/a deny-interfaces=vnet*' "$AVAHI_CONF"
    systemctl restart avahi-daemon
    echo "  → Avahi will ignore vnet*"
  else
    echo "  → Avahi already ignores vnet*"
  fi
fi

###############################################################################
# 8) enable IPv4 forwarding
###############################################################################
if [[ $(sysctl -n net.ipv4.ip_forward) -eq 0 ]]; then
  sysctl -w net.ipv4.ip_forward=1
  echo "Enabled IPv4 forwarding immediately."
else
  echo "IPv4 forwarding already enabled."
fi

if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  echo "Persisted IPv4 forwarding in /etc/sysctl.conf."
else
  echo "sysctl.conf already sets IPv4 forwarding."
fi

echo "All tasks complete. Reboot once to load firmware & apply persistent settings, then verify VM networking."
