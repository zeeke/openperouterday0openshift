#!/bin/bash
# NM dispatcher for OpenPERouter VF binding and address derivation.
#
# Shipped via butane to /etc/NetworkManager/dispatcher.d/99-perouter.
# Fires on any interface activation. Only acts on SR-IOV VFs:
#   - VF index 0 on any PF: bind for grout (perouter-bind.sh)
#   - VF with altname "host": derive addresses (perouter-host-dispatch.sh)

[ "$2" = "up" ] || exit 0

# If this is a PF with SR-IOV VFs, disable RA and IP on all VFs.
# Prevents eswitch-leaked RAs from poisoning the host routing table.
# The host VF re-enables what it needs via nmstate.
if [ -f "/sys/class/net/$1/device/sriov_numvfs" ]; then
	for vf_net in /sys/class/net/$1/device/virtfn*/net/*; do
		[ -d "$vf_net" ] || continue
		vf=$(basename "$vf_net")
		sysctl -w "net.ipv6.conf.$vf.accept_ra=0"
	done
	exit 0
fi

# Only act on SR-IOV VFs
physfn=/sys/class/net/$1/device/physfn
[ -d "$physfn" ] || exit 0

# Find VF index
vf_pci=$(readlink -f /sys/class/net/$1/device)
for vfn in "$physfn"/virtfn*; do
	[ "$(readlink -f "$vfn")" = "$vf_pci" ] || continue
	vf_idx=${vfn##*virtfn}
	[ "$vf_idx" = 0 ] && exec /usr/local/bin/perouter-bind.sh "$1"
	break
done

# Host VF: the VF carrying the default route
if ip -4 route show default dev "$1" 2>/dev/null | grep -q default; then
	exec /usr/local/bin/perouter-host-dispatch.sh "$1"
fi
