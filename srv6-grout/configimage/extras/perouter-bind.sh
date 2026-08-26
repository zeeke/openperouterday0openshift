#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

# Bind a network device for use in the perouter network namespace.
# For grout (DPDK) setups, also bind non-mlx5 devices to vfio-pci.
#
# Called from nmstate dispatch post-activation scripts.
# State is stored in /run/perouter-bind/<netdev> for setup-underlay.
#
# Usage: perouter-bind.sh <netdev> <netns>

STATE_DIR=/run/perouter-bind

die() { echo "error: $*" >&2; exit 1; }

if [ $# -lt 1 ]; then
	die "usage: $0 <netdev> [netns]"
fi
netdev=$1
netns=${2:-perouter}

# Idempotent: skip if already bound.
if [ -f "$STATE_DIR/$netdev" ]; then
	echo "$netdev: already bound, skipping"
	exit 0
fi

# Create netns if missing.
ip netns add "$netns" 2>/dev/null || true
ip -n "$netns" link set lo up
ip netns exec "$netns" sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec "$netns" sysctl -qw net.ipv4.conf.default.rp_filter=0

device=$(readlink -ve /sys/class/net/$netdev/device 2>/dev/null)
if [ -z "$device" ]; then
	die "$netdev: no such netdev"
fi

# For virtio NICs, /sys/class/net/<dev>/device points to the virtio bus
# device (e.g. virtio1), not the PCI device. Walk up to the PCI parent.
pci_addr=$(basename "$device")
case "$pci_addr" in
[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*)
	;;
*)
	device=$(dirname "$device")
	pci_addr=$(basename "$device")
	;;
esac

driver=$(basename $(readlink -ve "$device/driver"))
if [ -z "$driver" ]; then
	die "$netdev: cannot determine pci driver"
fi

set -e
mkdir -p "$STATE_DIR"

case "$driver" in
mlx5*)
	echo "Moving $netdev to $netns network namespace"
	ip link set $netdev netns $netns
	ip -n $netns link set $netdev up
	echo "mlx5 $driver $pci_addr" > "$STATE_DIR/$netdev"
	;;
*)
	echo "Binding $netdev ($pci_addr) to vfio-pci (was $driver)"
	/sbin/modprobe vfio-pci
	echo vfio-pci > /sys/bus/pci/devices/$pci_addr/driver_override
	echo $pci_addr > /sys/bus/pci/drivers/$driver/unbind || true
	echo $pci_addr > /sys/bus/pci/drivers/vfio-pci/bind
	echo "vfio $driver $pci_addr" > "$STATE_DIR/$netdev"
	;;
esac
