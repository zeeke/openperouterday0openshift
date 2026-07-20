#!/bin/bash
set -euo pipefail

# setup-underlay.sh - Set up underlay infrastructure for OpenPERouter (ISIS + SRv6)
#
# This script:
# 1. Waits for FRR container to be ready
# 2. Derives addressing from host VF / br-ex (Router ID, IPv6 loopbacks, SRv6 locator, ISIS NET)
# 3. Adds underlay and trunk NICs to grout via grcli
# 4. Assigns addresses (underlay IPv6, VTEP, loopback, SRv6 source) via grcli
# 5. Saves variables for config generation
#
# Usage: Executed by systemd service setup-underlay.service
#
# Exit codes:
#   0   - Success
#   1   - General error
#   124 - Timeout waiting for FRR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found at $SCRIPT_DIR/openperouter-common.sh" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

# Load environment configuration file
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# Verify required functions
for func in frr_netns_pid isfrr_ready; do
    if ! declare -f "$func" >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Required function $func not found in openperouter-common.sh" >&2
        exit 1
    fi
done

# Load environment variables with defaults

FRR_READY_TIMEOUT="${FRR_READY_TIMEOUT:-60}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
ISIS_AREA="${ISIS_AREA:-49.0001}"
TRUNK_NIC="${TRUNK_NIC:-eno12399v1}"
TRUNK_VLAN="${TRUNK_NIC}.42"

# Output file for variables
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"

# Start main execution
log "Starting underlay setup (ISIS + SRv6 mode)"
log "Configuration: UNDERLAY_NIC=$UNDERLAY_NIC, NODE_NAME=$NODE_NAME"

#
# STEP 1: Wait for FRR container to be ready
#
log_step "Waiting for FRR container"
log "Timeout configured: ${FRR_READY_TIMEOUT}s"
ELAPSED=0
INTERVAL=2

while ! isfrr_ready 2>/dev/null; do
    if [ $ELAPSED -ge $FRR_READY_TIMEOUT ]; then
        error "FRR not ready after ${FRR_READY_TIMEOUT}s timeout"
        error "Check FRR container: podman ps | grep frr"
        error "Check FRR logs: podman logs frr"
        exit_timeout
    fi
    if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log "Still waiting for FRR... (${ELAPSED}s elapsed)"
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

log "FRR container is ready"

#
# STEP 2: Derive addressing from br0 (or br-ex after OVN takes over)
#
log_step "Deriving addressing from bridge interface"

HOST_VF="${HOST_VF:-eno12399v2}"
HOST_IP_TIMEOUT="${HOST_IP_TIMEOUT:-120}"
HOST_ELAPSED=0
HOST_INTERVAL=2
HOST_IP=""
HOST_IFACE=""

while [[ -z "$HOST_IP" ]]; do
    for iface in "$HOST_VF" br-ex; do
        if ip link show "$iface" >/dev/null 2>&1; then
            HOST_IP=$(ip -j -4 addr show "$iface" 2>/dev/null | jq -r '.[0].addr_info[0].local // empty')
            if [[ -n "$HOST_IP" ]]; then
                HOST_IFACE="$iface"
                break
            fi
        fi
    done
    if [[ -n "$HOST_IP" ]]; then
        break
    fi
    if [ $HOST_ELAPSED -ge $HOST_IP_TIMEOUT ]; then
        error "No host interface ($HOST_VF/br-ex) has an IP after ${HOST_IP_TIMEOUT}s"
        exit_error "Host interface must have an IP address configured"
    fi
    if [ $((HOST_ELAPSED % 10)) -eq 0 ] && [ $HOST_ELAPSED -gt 0 ]; then
        log "Waiting for host IP address... (${HOST_ELAPSED}s elapsed)"
    fi
    sleep $HOST_INTERVAL
    HOST_ELAPSED=$((HOST_ELAPSED + HOST_INTERVAL))
done

# Extract last octet — used as node index for all addressing
LAST_OCTET=$(echo "$HOST_IP" | cut -d. -f4)

# Derive all addresses from node index
ROUTER_ID="10.0.0.${LAST_OCTET}"
VTEP_IP="$ROUTER_ID"
LOOPBACK_V6="fc00:0:${LAST_OCTET}::1"
SRV6_SOURCE="fd00:${LAST_OCTET}::1"
SRV6_PREFIX="fd00:${LAST_OCTET}"
SRV6_NODE_ID="${LAST_OCTET}"
UNDERLAY_V6="fc00:100::${LAST_OCTET}"
ISIS_NET="${ISIS_AREA}.0000.0000.$(printf '%04d' "${LAST_OCTET}").00"

HOST_IP_V6=""
HOST_V6_ELAPSED=0
while [[ -z "$HOST_IP_V6" ]]; do
    HOST_IP_V6=$(ip -6 addr show "$HOST_IFACE" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1 || true)
    if [[ -n "$HOST_IP_V6" ]]; then
        break
    fi
    if [ $HOST_V6_ELAPSED -ge $HOST_IP_TIMEOUT ]; then
        log "WARNING: No IPv6 address on $HOST_IFACE after ${HOST_IP_TIMEOUT}s — continuing without it"
        break
    fi
    if [ $((HOST_V6_ELAPSED % 10)) -eq 0 ] && [ $HOST_V6_ELAPSED -gt 0 ]; then
        log "Waiting for bridge IPv6 address... (${HOST_V6_ELAPSED}s elapsed)"
    fi
    sleep $HOST_INTERVAL
    HOST_V6_ELAPSED=$((HOST_V6_ELAPSED + HOST_INTERVAL))
done

log "VF interface: $HOST_IFACE, IP: $HOST_IP, IPv6: ${HOST_IP_V6:-none}"
log "Node index (last octet): $LAST_OCTET"
log "  Router ID / VTEP IP: $ROUTER_ID"
log "  Loopback IPv6:       $LOOPBACK_V6"
log "  SRv6 source:         $SRV6_SOURCE"
log "  SRv6 locator:        $SRV6_PREFIX:$SRV6_NODE_ID::/48"
log "  Underlay IPv6:       $UNDERLAY_V6"
log "  ISIS NET:            $ISIS_NET"

#
# STEP 3: Add underlay and trunk NICs to grout
#
log_step "Configuring underlay NIC via grout"

FRR_PID=$(frr_netns_pid)
if [[ -z "$FRR_PID" || "$FRR_PID" == "0" ]]; then
    error "Failed to get FRR container PID"
    exit_error "Cannot determine FRR namespace"
fi

log "FRR container PID: $FRR_PID"

UNDERLAY_PCI=$(cut -d' ' -f3 "/run/grout-bind/$UNDERLAY_NIC") ||
    exit_error "Failed to determine underlay NIC $UNDERLAY_NIC PCI address"
TRUNK_PCI=$(cut -d' ' -f3 "/run/grout-bind/$TRUNK_NIC") ||
    exit_error "Failed to determine trunk NIC $TRUNK_NIC PCI address"

grcli() {
    echo "+ grcli $*"
    podman exec grout grcli "$@"
}

log "Adding $UNDERLAY_NIC to grout (PCI: $UNDERLAY_PCI)..."
grcli interface add port "$UNDERLAY_NIC" devargs "$UNDERLAY_PCI"

log "Adding $TRUNK_NIC to grout (PCI: $TRUNK_PCI)..."
grcli interface add port $TRUNK_NIC devargs $TRUNK_PCI

log "$UNDERLAY_NIC and $TRUNK_NIC configured via grout"

# Add IPv6 address to underlay NIC for ISIS adjacency
log "Adding IPv6 $UNDERLAY_V6/64 to $UNDERLAY_NIC..."
grcli address add $UNDERLAY_V6/64 iface "$UNDERLAY_NIC" || {
    log "WARNING: IPv6 address may already be configured"
}

#
# STEP 4: Configure addresses for BGP peering and SRv6 via grout
#
log_step "Configuring loopback and SRv6 addresses via grout"

log "Adding VTEP IP $VTEP_IP/32 to $UNDERLAY_NIC..."
grcli address add ${VTEP_IP}/32 iface $UNDERLAY_NIC || {
    log "WARNING: VTEP IP may already be configured"
}

log "Adding IPv6 loopback $LOOPBACK_V6/128 to $UNDERLAY_NIC..."
grcli address add ${LOOPBACK_V6}/128 iface $UNDERLAY_NIC || {
    log "WARNING: IPv6 loopback may already be configured"
}

log "Adding SRv6 source $SRV6_SOURCE/128 to $UNDERLAY_NIC..."
grcli address add ${SRV6_SOURCE}/128 iface $UNDERLAY_NIC || {
    log "WARNING: SRv6 source may already be configured"
}

log "Address configuration complete"

#
# STEP 5: Save variables for config generation
#
log_step "Saving variables for config generation"

# Create directory if needed
mkdir -p "$(dirname "$VARS_FILE")"

# Compute derived values before writing
BR0_IP="$HOST_IP"
BR0_IP_V6="${HOST_IP_V6:-}"
BR0_SUBNET="${HOST_IP%.*}.0/24"
BR0_SUBNET_V6=""
if [[ -n "$BR0_IP_V6" ]]; then
    BR0_SUBNET_V6="$(echo "$BR0_IP_V6" | sed 's/:[^:]*$//' | sed 's/:*$//')::/64"
fi

# Write variables (will be sourced by generate-config.sh and setup-network.sh)
cat > "$VARS_FILE" <<EOF
# OpenPERouter VPN Setup Variables (ISIS + SRv6)
# Generated by setup-underlay.sh on $(date +'%Y-%m-%d %H:%M:%S')

# Node identity
NODE_NAME="$NODE_NAME"
LAST_OCTET="$LAST_OCTET"

# Router ID and VTEP (same address — L2 VXLAN uses router-id as source)
ROUTER_ID="$ROUTER_ID"
VTEP_IP="$VTEP_IP"
BR0_IP="$BR0_IP"
BR0_IP_V6="$BR0_IP_V6"
BR0_SUBNET="$BR0_SUBNET"
BR0_SUBNET_V6="$BR0_SUBNET_V6"

# IPv6 loopback for BGP peering
LOOPBACK_V6="$LOOPBACK_V6"

# SRv6 addressing
SRV6_SOURCE="$SRV6_SOURCE"
SRV6_PREFIX="$SRV6_PREFIX"
SRV6_NODE_ID="$SRV6_NODE_ID"

# Underlay IPv6
UNDERLAY_V6="$UNDERLAY_V6"

# ISIS
ISIS_NET="$ISIS_NET"

# Underlay NIC
UNDERLAY_NIC="$UNDERLAY_NIC"
FRR_PID="$FRR_PID"
EOF

chmod 644 "$VARS_FILE"

log "Variables saved to $VARS_FILE"

exit_success "Underlay setup completed successfully"
