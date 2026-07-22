#!/bin/bash
# NM dispatcher for OpenPERouter VF binding and address derivation.
#
# Shipped via butane to /etc/NetworkManager/dispatcher.d/99-perouter.
# Fires on any interface activation. Only acts on SR-IOV VFs:
#   - VF index 0 on any PF: bind for grout (perouter-bind.sh)
#   - VF with altname "host": derive addresses (perouter-host-dispatch.sh)

[ "$2" = "up" ] || exit 0

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

# Host VF: identified by altname
ip link show "$1" | grep -q 'altname host' \
	&& exec /usr/local/bin/perouter-host-dispatch.sh "$1"
