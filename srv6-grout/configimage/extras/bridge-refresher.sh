#!/bin/bash
set -euo pipefail

# bridge-refresher.sh - Mimic the OpenPERouter bridge refresher logic
#
# The full OpenPERouter controller has a bridge refresher that proactively
# resolves ARP for VIPs on the EVPN bridge. Without it, Keepalived GARPs
# on br-ex never create neighbor entries on br-pe-210 in the FRR namespace,
# so EVPN type-2 routes are never advertised and VIPs are unreachable from
# remote PEs. This script fills that gap for rawconfig deployments.

source /etc/openperouter/openperouter.env
source /var/lib/openperouter/vpn-setup.vars

: ${REFRESH_INTERVAL:=10}
: ${BRIDGE_NAME:="br-pe-${L2_VNI}"}

# Strip CIDR prefix to get the subnet base for VIP discovery
GATEWAY_SUBNET="${L2_GATEWAY_IP%.*}"

# VIPs to keep alive — API and Ingress
API_VIP="${API_VIP:-${GATEWAY_SUBNET}.10}"
INGRESS_VIP="${INGRESS_VIP:-${GATEWAY_SUBNET}.11}"

# Workaround for FRR #21190: zebra silently ignores FDB notifications
# until advertise-all-vni has taken effect and it knows about the VNI.
# The VLAN bridge port must be added after zebra has learned the VNI,
# otherwise MAC learning events are lost. Fixed in FRR 10.7.
echo "Waiting for zebra to learn VNI ${L2_VNI}..."

while true; do
	echo "bridge-refresher disabled"
	sleep 300
done



while ! podman exec frr vtysh -c "show evpn vni ${L2_VNI}" 2>/dev/null | grep -q "VNI: ${L2_VNI}"; do
	sleep 1
done
echo "VNI ${L2_VNI} discovered, adding VLAN bridge port (VLAN $HOST_VLAN)"

grcli() {
	echo "+ grcli $*" >&2
	podman exec grout grcli "$@"
}

n=0
for state in /run/perouter-bind/*; do
	[ -f "$state" ] || continue
	port="underlay$n"
	grcli interface add vlan $port.$HOST_VLAN parent $port vlan_id $HOST_VLAN domain $BRIDGE_NAME
	n=$((n + 1))
done

echo "Bridge refresher started (interval=${REFRESH_INTERVAL}s, bridge=${BRIDGE_NAME})"
echo "  VIPs: $API_VIP, $INGRESS_VIP"

while true; do
	for vip in "$API_VIP" "$INGRESS_VIP"; do
		podman exec grout grcli ping "$vip" vrf red count 1 >/dev/null 2>&1 || true
	done
	sleep "$REFRESH_INTERVAL"
done
