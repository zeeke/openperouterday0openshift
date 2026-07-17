#!/bin/bash
set -euo pipefail

# setup-network.sh - Network infrastructure setup for SRv6 + L2 EVPN
#
# This script creates the network infrastructure (VRF, L2 VXLAN, bridges, veths)
# in the FRR namespace. L3VPN is handled by SRv6 (no L3VNI VXLAN needed).
# L2VPN still uses VXLAN overlay.
#
# Usage: Executed by setup-network.service after setup-underlay.service
#
# Exit codes:
#   0   - Success
#   1   - Error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

# Load variables from setup-underlay.sh if available
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"
if [[ -f "$VARS_FILE" ]]; then
    log "Loading variables from $VARS_FILE"
    source "$VARS_FILE"
else
    log "Variables file not found, using environment variables"
fi

# Parameters (from environment or defaults)
VRF_NAME="${VRF_NAME:-red}"
VRF_TABLE="${VRF_TABLE:-1100}"
L2_VNI="${L2_VNI:-210}"
VXLAN_PORT="${VXLAN_PORT:-4789}"
L2_GATEWAY_IP="${L2_GATEWAY_IP:-192.168.110.1/24}"
L2_GATEWAY_IP_V6="${L2_GATEWAY_IP_V6:-fd00:110::1/64}"
VTEP_IP="${VTEP_IP}"
VTEP_INTERFACE="${VTEP_INTERFACE:-lo}"

if [[ -z "$VTEP_IP" ]]; then
    error "VTEP_IP not set - must be provided via $VARS_FILE or environment"
    error "Run setup-underlay.service first to generate variables"
    exit 1
fi

# Get FRR namespace PID
FRR_PID=$(frr_netns_pid)
if [[ -z "$FRR_PID" || "$FRR_PID" == "0" ]]; then
    error "Failed to get FRR container PID"
    exit 1
fi

log "Setting up network infrastructure in FRR namespace (PID: $FRR_PID)"
log "Configuration: VRF=$VRF_NAME (table $VRF_TABLE), L2_VNI=$L2_VNI, VTEP_IP=$VTEP_IP"

# Helper function: run command in FRR namespace
infrr() {
    inns "$@"
}

#
# STEP 0a: Enable IP forwarding in FRR namespace
#
log "Step 0a: Enabling IP forwarding in FRR namespace"
infrr sysctl -w net.ipv4.ip_forward=1 || {
    error "Failed to enable IPv4 forwarding"
    exit 1
}
infrr sysctl -w net.ipv4.conf.all.forwarding=1 || true
infrr sysctl -w net.ipv6.conf.all.forwarding=1 || true
log "  IP forwarding enabled (IPv4 and IPv6)"

#
# STEP 0b: Add VTEP IP to loopback in FRR namespace
#
log "Step 0b: Adding VTEP IP to loopback in FRR namespace"

if infrr ip addr show "$VTEP_INTERFACE" | grep -q "$VTEP_IP"; then
    log "  VTEP IP $VTEP_IP already assigned to $VTEP_INTERFACE"
else
    infrr ip addr add "${VTEP_IP}/32" dev "$VTEP_INTERFACE" || {
        error "Failed to add VTEP IP to $VTEP_INTERFACE"
        exit 1
    }
    infrr ip link set "$VTEP_INTERFACE" up || true
    log "  VTEP IP $VTEP_IP/32 added to $VTEP_INTERFACE"
fi

#
# STEP 1: Create VRF in FRR namespace
#
log "Step 1: Creating VRF '$VRF_NAME' (table $VRF_TABLE)"

if infrr ip link show "$VRF_NAME" >/dev/null 2>&1; then
    log "  VRF '$VRF_NAME' already exists"
else
    infrr ip link add "$VRF_NAME" type vrf table "$VRF_TABLE" || {
        error "Failed to create VRF $VRF_NAME"
        exit 1
    }
    infrr ip link set "$VRF_NAME" up || {
        error "Failed to bring up VRF $VRF_NAME"
        exit 1
    }
    log "  VRF '$VRF_NAME' created successfully"
fi

# VRF strict mode (must be after VRF creation so the kernel module is loaded)
infrr sysctl -w net.vrf.strict_mode=1 2>/dev/null || {
    log "  WARNING: VRF strict mode not available"
}
# Disable rp_filter for SRv6 decapsulation
infrr sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
infrr sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
infrr sysctl -w "net.ipv4.conf.${VRF_NAME}.rp_filter=0" 2>/dev/null || true

#
# STEP 2: Create L2VNI bridge in FRR namespace
#
L2_BRIDGE="br-pe-${L2_VNI}"
log "Step 2: Creating L2VNI bridge '$L2_BRIDGE'"

if infrr ip link show "$L2_BRIDGE" >/dev/null 2>&1; then
    log "  Bridge '$L2_BRIDGE' already exists"
else
    infrr ip link add "$L2_BRIDGE" type bridge || {
        error "Failed to create bridge $L2_BRIDGE"
        exit 1
    }
    infrr ip link set "$L2_BRIDGE" master "$VRF_NAME" || {
        error "Failed to enslave bridge to VRF"
        exit 1
    }
    infrr sysctl -w "net.ipv6.conf.${L2_BRIDGE}.addr_gen_mode=1" 2>/dev/null || true
    infrr ip link set "$L2_BRIDGE" up || {
        error "Failed to bring up bridge $L2_BRIDGE"
        exit 1
    }
    log "  Bridge '$L2_BRIDGE' created and enslaved to VRF"
fi

#
# STEP 3: Assign L2 gateway IP to bridge
#
log "Step 3: Assigning gateway IP to L2 bridge"

if infrr ip addr show "$L2_BRIDGE" | grep -q "$L2_GATEWAY_IP"; then
    log "  Gateway IP already assigned"
else
    infrr ip addr add "$L2_GATEWAY_IP" dev "$L2_BRIDGE" || {
        error "Failed to assign gateway IP to bridge"
        exit 1
    }
    # Set deterministic MAC address based on VNI (00:F3:00:00:00:VNI+1)
    MAC_SUFFIX=$(printf "%02x" $((L2_VNI + 1)))
    MAC_ADDR="00:f3:00:00:00:${MAC_SUFFIX}"
    infrr ip link set "$L2_BRIDGE" address "$MAC_ADDR" 2>/dev/null || true
    log "  Gateway IP $L2_GATEWAY_IP assigned to bridge"
fi

if [[ -n "${L2_GATEWAY_IP_V6}" ]]; then
    if infrr ip -6 addr show "$L2_BRIDGE" | grep -q "${L2_GATEWAY_IP_V6%/*}"; then
        log "  IPv6 gateway IP already assigned"
    else
        infrr ip -6 addr add "$L2_GATEWAY_IP_V6" dev "$L2_BRIDGE" || {
            error "Failed to assign IPv6 gateway IP to bridge"
            exit 1
        }
        log "  IPv6 gateway IP $L2_GATEWAY_IP_V6 assigned to bridge"
    fi
fi

#
# STEP 4: Create L2VNI VXLAN interface in FRR namespace
#
L2_VXLAN="vni${L2_VNI}"
log "Step 4: Creating L2VNI VXLAN interface '$L2_VXLAN'"

if infrr ip link show "$L2_VXLAN" >/dev/null 2>&1; then
    log "  VXLAN '$L2_VXLAN' already exists"
else
    infrr ip link add "$L2_VXLAN" type vxlan \
        id "$L2_VNI" \
        local "$VTEP_IP" \
        dstport "$VXLAN_PORT" \
        nolearning || {
        error "Failed to create VXLAN $L2_VXLAN"
        exit 1
    }
    infrr ip link set "$L2_VXLAN" master "$L2_BRIDGE" || {
        error "Failed to enslave VXLAN to bridge"
        exit 1
    }
    infrr sysctl -w "net.ipv6.conf.${L2_VXLAN}.addr_gen_mode=1" 2>/dev/null || true
    infrr ip link set "$L2_VXLAN" type bridge_slave neigh_suppress on 2>/dev/null || true
    infrr ip link set "$L2_VXLAN" up || {
        error "Failed to bring up VXLAN $L2_VXLAN"
        exit 1
    }
    log "  VXLAN '$L2_VXLAN' created and enslaved to bridge"
fi

#
# STEP 5: Create veth pair for L2VNI (host <-> FRR namespace)
#
HOST_VETH="host-${L2_VNI}"
PE_VETH="pe-${L2_VNI}"
log "Step 5: Creating veth pair for L2VNI: $HOST_VETH <-> $PE_VETH"

if ip link show "$HOST_VETH" >/dev/null 2>&1; then
    log "  Veth pair already exists"
else
    ip link add "$HOST_VETH" type veth peer name "$PE_VETH" || {
        error "Failed to create veth pair"
        exit 1
    }
    log "  Veth pair created"

    ip link set "$PE_VETH" netns "$FRR_PID" || {
        error "Failed to move $PE_VETH to FRR namespace"
        exit 1
    }
    log "  Moved $PE_VETH to FRR namespace"

    ip link set "$HOST_VETH" up || {
        error "Failed to bring up $HOST_VETH"
        exit 1
    }

    infrr ip link set "$PE_VETH" master "$L2_BRIDGE" || {
        error "Failed to enslave $PE_VETH to bridge"
        exit 1
    }
    infrr ip link set "$PE_VETH" up || {
        error "Failed to bring up $PE_VETH in namespace"
        exit 1
    }
    log "  Veth $PE_VETH enslaved to $L2_BRIDGE and brought up"
fi

#
# STEP 6: Attach host-side veth to br0
#
log "Step 6: Attaching $HOST_VETH to br0"

if ! ip link show br0 >/dev/null 2>&1; then
    error "br0 bridge does not exist - cannot attach veth"
    exit 1
fi

if ip link show "$HOST_VETH" | grep -q "master br0"; then
    log "  $HOST_VETH already attached to br0"
else
    ip link set "$HOST_VETH" master br0 || {
        error "Failed to attach $HOST_VETH to br0"
        exit 1
    }
    log "  $HOST_VETH attached to br0"
fi

log ""
log "Network infrastructure setup completed successfully!"
log ""
log "Summary:"
log "  VRF: $VRF_NAME (table $VRF_TABLE)"
log "  L2VNI: Bridge=$L2_BRIDGE, VXLAN=$L2_VXLAN, VNI=$L2_VNI"
log "  L2 Gateway IP: $L2_GATEWAY_IP (v6: ${L2_GATEWAY_IP_V6:-none})"
log "  Veth pair: $HOST_VETH (on br0) <-> $PE_VETH (on $L2_BRIDGE)"
log "  VTEP IP: $VTEP_IP"
log "  L3VPN: handled by SRv6 (no L3VNI VXLAN)"
log ""

exit 0
