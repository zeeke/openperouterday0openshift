#!/bin/bash
# generate-vpn-env.sh - Generate /etc/openperouter/vpn-setup.env at boot time.
#
# Reads cluster-wide defaults from vpn-setup.env.defaults, auto-detects
# SR-IOV VF names from sysfs, and writes the final env file.
#
# This script must never fail -- if SR-IOV is not available (BIOS
# disabled, no VFs yet), it writes the defaults file as-is and exits
# successfully so it does not block the boot chain.
#
# Usage: Executed by systemd service generate-vpn-env.service

set -uo pipefail

DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/openperouter/vpn-setup.env.defaults}"
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"

log() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Start with cluster-wide defaults
if [[ -f "$DEFAULTS_FILE" ]]; then
	log "Loading defaults from $DEFAULTS_FILE"
	cp "$DEFAULTS_FILE" "$ENV_FILE"
else
	log "No defaults file found at $DEFAULTS_FILE, starting empty"
	: > "$ENV_FILE"
fi

# Wait for an SR-IOV PF with VFs to appear. nmstate may still be
# configuring SR-IOV when this script starts.
VF_TIMEOUT="${VF_TIMEOUT:-300}"
PF_NAME=""
SECONDS=0

while [[ -z "$PF_NAME" ]]; do
	for numvfs_path in /sys/class/net/*/device/sriov_numvfs; do
		[[ -f "$numvfs_path" ]] || continue
		numvfs=$(cat "$numvfs_path" 2>/dev/null) || continue
		if [[ "$numvfs" -gt 0 ]]; then
			pf_dir=$(dirname "$(dirname "$numvfs_path")")
			PF_NAME=$(basename "$pf_dir")
			break
		fi
	done
	[[ -n "$PF_NAME" ]] && break
	if [[ $SECONDS -ge $VF_TIMEOUT ]]; then
		log "WARNING: no SR-IOV PF with VFs after ${VF_TIMEOUT}s, skipping"
		chmod 644 "$ENV_FILE"
		exit 0
	fi
	log "Waiting for SR-IOV VFs... (${SECONDS}s)"
	sleep 2
done

log "Detected SR-IOV PF: $PF_NAME"

# Wait for VF0, VF1, VF2 net devices to appear under the PF.
# nmstate may still be configuring VFs (VLAN tags, IPs) after
# sriov_numvfs is set.
pf_device="/sys/class/net/$PF_NAME/device"
UNDERLAY_NIC=""
TRUNK_NIC=""
HOST_VF=""

while [[ -z "$UNDERLAY_NIC" ]] || [[ -z "$TRUNK_NIC" ]] || [[ -z "$HOST_VF" ]]; do
	for virtfn in "$pf_device"/virtfn*; do
		[[ -d "$virtfn" ]] || continue
		idx=$(basename "$virtfn" | sed 's/virtfn//')
		vf_name=$(ls "$virtfn/net" 2>/dev/null | head -1)
		[[ -n "$vf_name" ]] || continue
		case "$idx" in
		0) UNDERLAY_NIC="$vf_name" ;;
		1) TRUNK_NIC="$vf_name" ;;
		2) HOST_VF="$vf_name" ;;
		esac
	done
	if [[ -n "$UNDERLAY_NIC" ]] && [[ -n "$TRUNK_NIC" ]] && [[ -n "$HOST_VF" ]]; then
		break
	fi
	if [[ $SECONDS -ge $VF_TIMEOUT ]]; then
		log "WARNING: not all VFs detected after ${VF_TIMEOUT}s (UNDERLAY=$UNDERLAY_NIC, TRUNK=$TRUNK_NIC, HOST=$HOST_VF)"
		break
	fi
	log "Waiting for VF net devices... (UNDERLAY=$UNDERLAY_NIC, TRUNK=$TRUNK_NIC, HOST=$HOST_VF)"
	sleep 2
done

# Disable accept_ra on all VFs except the host VF. The eswitch
# forwards RA packets between VFs on the same PF, causing unused VFs
# to learn default routes that override the host VF's static default.
for virtfn in "$pf_device"/virtfn*; do
	[[ -d "$virtfn" ]] || continue
	vf_name=$(ls "$virtfn/net" 2>/dev/null | head -1)
	[[ -n "$vf_name" ]] || continue
	[[ "$vf_name" == "$HOST_VF" ]] && continue
	sysctl -w "net.ipv6.conf.${vf_name}.accept_ra=0"
done

# Append detected NIC names to the env file
{
	echo ""
	echo "# Auto-detected SR-IOV VF names (PF: $PF_NAME)"
	[[ -n "$UNDERLAY_NIC" ]] && echo "UNDERLAY_NIC=$UNDERLAY_NIC"
	[[ -n "$TRUNK_NIC" ]] && echo "TRUNK_NIC=$TRUNK_NIC"
	[[ -n "$HOST_VF" ]] && echo "HOST_VF=$HOST_VF"
} >> "$ENV_FILE"

chmod 644 "$ENV_FILE"

log "Generated $ENV_FILE (UNDERLAY_NIC=$UNDERLAY_NIC, TRUNK_NIC=$TRUNK_NIC, HOST_VF=$HOST_VF)"

# Enable grout-bind@ instances for the detected VFs
units=""
[[ -n "$UNDERLAY_NIC" ]] && units="grout-bind@${UNDERLAY_NIC}.service"
[[ -n "$TRUNK_NIC" ]] && units="$units grout-bind@${TRUNK_NIC}.service"

if [[ -n "$units" ]]; then
	log "Enabling and starting $units"
	systemctl daemon-reload
	systemctl enable $units
	systemctl start --no-block $units
fi
