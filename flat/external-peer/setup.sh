#!/bin/bash
set -euo pipefail

# setup.sh - Configure the bastion as an ISIS-routed NAT gateway and DNS server
#
# Idempotent — safe to run multiple times.
#
# Host: dell-r450-nfv2023-04.lab.eng.brq2.redhat.com
# Private NIC: eno12399np0 (connected to switch et-0/0/6)
# Public NIC:  eno8303 (10.37.146.46/23, internet access)
#
# Network setup uses ip commands (ephemeral). Re-run after reboot.

PRIVATE_NIC="eno12399np0"
PUBLIC_NIC="eno8303"
PRIVATE_NET="192.168.110.0/24"
PRIVATE_NET_V6="fd00:110::/64"
FRR_IMAGE="quay.io/frrouting/frr:10.6.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tell NetworkManager to leave the private NIC alone ---

cat > /etc/NetworkManager/conf.d/99-unmanaged-private.conf <<NM
[keyfile]
unmanaged-devices=interface-name:${PRIVATE_NIC}
NM
nmcli general reload

# --- IP forwarding ---

cat > /etc/sysctl.d/99-ip-forward.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl --system >/dev/null

# --- Private interface (unnumbered link to switch) ---

ip link set "$PRIVATE_NIC" up

# --- NAT (firewalld) ---
# Set zones via NetworkManager so they survive reloads.

PUBLIC_NM_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$PUBLIC_NIC" '$2==d{print $1}')
if [[ -n "$PUBLIC_NM_CON" ]]; then
	nmcli con mod "$PUBLIC_NM_CON" connection.zone external
	nmcli con up "$PUBLIC_NM_CON"
fi

firewall-cmd --zone=external --add-masquerade --permanent
firewall-cmd --zone=external --add-service=http --permanent
firewall-cmd --zone=trusted --add-source="$PRIVATE_NET" --permanent
firewall-cmd --zone=trusted --add-source="$PRIVATE_NET_V6" --permanent
firewall-cmd --zone=trusted --add-source=10.0.0.0/24 --permanent
firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 \
	-s "$PRIVATE_NET_V6" -o "$PUBLIC_NIC" -j MASQUERADE 2>/dev/null || true
firewall-cmd --add-service=http --permanent
firewall-cmd --reload

# --- Containerized FRR ---

systemctl disable frr --now 2>/dev/null || true

mkdir -p /etc/frr
cp "${SCRIPT_DIR}/frr.conf" /etc/frr/frr.conf

cat > /etc/frr/daemons <<DAEMONS
zebra=yes
isisd=yes
staticd=yes
DAEMONS

podman pull "$FRR_IMAGE"
podman rm -f frr 2>/dev/null || true
podman run -d --name frr --rm \
	--network=host \
	--privileged \
	-v /etc/frr:/etc/frr:Z \
	"$FRR_IMAGE"

# --- dnsmasq (main namespace) ---

cp "${SCRIPT_DIR}/dnsmasq.conf" /etc/dnsmasq.d/sno.conf

# NM dnsmasq plugin forwards sno-lab queries to our dnsmasq instance
mkdir -p /etc/NetworkManager/dnsmasq.d
cat > /etc/NetworkManager/dnsmasq.d/sno-lab.conf <<DNSMASQ
server=/sno-lab.example.com/10.0.0.4
DNSMASQ

if ! grep -q 'dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf; then
	sed -i '/^\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
fi
nmcli general reload

systemctl daemon-reload
systemctl enable dnsmasq
systemctl restart dnsmasq

# API hostname for oc
grep -qF api.sno-lab.example.com /etc/hosts || \
	echo "192.168.110.2 api.sno-lab.example.com api-int.sno-lab.example.com" >> /etc/hosts

# --- nginx ---

dnf install -y nginx

systemctl enable nginx
systemctl start nginx

echo "==> Bastion setup complete (flat / static routing)"
