#!/bin/bash
# Disable accept_ra on all SR-IOV VFs to prevent SLAAC addresses.
# The eswitch forwards RAs between VFs on the same PF, causing unused
# VFs to acquire addresses and default routes from the switch.

set -euo pipefail

for numvfs_path in /sys/class/net/*/device/sriov_numvfs; do
	[ -f "$numvfs_path" ] || continue
	numvfs=$(cat "$numvfs_path" 2>/dev/null) || continue
	[ "$numvfs" -gt 0 ] || continue
	pf_device=$(dirname "$(dirname "$numvfs_path")")
	for virtfn in "$pf_device"/device/virtfn*/net/*; do
		[ -d "$virtfn" ] || continue
		vf_name=$(basename "$virtfn")
		sysctl -w "net.ipv6.conf.${vf_name}.accept_ra=0"
	done
done
