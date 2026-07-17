#!/bin/bash
set -euo pipefail

# setup-underlay.sh - Set up underlay infrastructure for OpenPERouter (ISIS + SRv6)
#
# This script:
# 1. Waits for FRR container to be ready
# 2. Derives addressing from br0 (Router ID, IPv6 loopbacks, SRv6 locator, ISIS NET)
# 3. Configures underlay NIC:
#    - If grout-bind ran (masters): uses grcli to add the port to grout
#    - Otherwise (workers): moves NIC to FRR namespace via ip link set netns
# 4. Configures IPv4/IPv6 loopback addresses and SRv6 sysctls in FRR namespace
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
for func in frr_netns_pid inns isfrr_ready; do
    if ! declare -f "$func" >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Required function $func not found in openperouter-common.sh" >&2
        exit 1
    fi
done

# Load environment variables with defaults

FRR_READY_TIMEOUT="${FRR_READY_TIMEOUT:-60}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
ISIS_AREA="${ISIS_AREA:-49.0001}"

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

BR0_READY_TIMEOUT="${BR0_READY_TIMEOUT:-120}"
BR0_ELAPSED=0
BR0_INTERVAL=2
BR0_IP=""
BRIDGE_IFACE=""

while [[ -z "$BR0_IP" ]]; do
    for iface in br0 br-ex; do
        if ip link show "$iface" >/dev/null 2>&1; then
            BR0_IP=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
            if [[ -n "$BR0_IP" ]]; then
                BRIDGE_IFACE="$iface"
                break
            fi
        fi
    done
    if [[ -n "$BR0_IP" ]]; then
        break
    fi
    if [ $BR0_ELAPSED -ge $BR0_READY_TIMEOUT ]; then
        error "No bridge interface (br0/br-ex) has an IP after ${BR0_READY_TIMEOUT}s"
        error "Check: ip addr show br0; ip addr show br-ex"
        exit_error "Bridge interface must have an IP address configured"
    fi
    if [ $((BR0_ELAPSED % 10)) -eq 0 ] && [ $BR0_ELAPSED -gt 0 ]; then
        log "Waiting for bridge IP address... (${BR0_ELAPSED}s elapsed)"
    fi
    sleep $BR0_INTERVAL
    BR0_ELAPSED=$((BR0_ELAPSED + BR0_INTERVAL))
done

# Extract last octet — used as node index for all addressing
LAST_OCTET=$(echo "$BR0_IP" | cut -d. -f4)

# Derive all addresses from node index
ROUTER_ID="10.0.0.${LAST_OCTET}"
VTEP_IP="$ROUTER_ID"
LOOPBACK_V6="fc00:0:${LAST_OCTET}::1"
SRV6_SOURCE="fd00:${LAST_OCTET}::1"
SRV6_PREFIX="fd00:${LAST_OCTET}"
SRV6_NODE_ID="${LAST_OCTET}"
UNDERLAY_V6="fc00:100::${LAST_OCTET}"
ISIS_NET="${ISIS_AREA}.0000.0000.$(printf '%04d' "${LAST_OCTET}").00"

BR0_IP_V6=""
BR0_V6_ELAPSED=0
while [[ -z "$BR0_IP_V6" ]]; do
    BR0_IP_V6=$(ip -6 addr show "$BRIDGE_IFACE" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1 || true)
    if [[ -n "$BR0_IP_V6" ]]; then
        break
    fi
    if [ $BR0_V6_ELAPSED -ge $BR0_READY_TIMEOUT ]; then
        log "WARNING: No IPv6 address on $BRIDGE_IFACE after ${BR0_READY_TIMEOUT}s — continuing without it"
        break
    fi
    if [ $((BR0_V6_ELAPSED % 10)) -eq 0 ] && [ $BR0_V6_ELAPSED -gt 0 ]; then
        log "Waiting for bridge IPv6 address... (${BR0_V6_ELAPSED}s elapsed)"
    fi
    sleep $BR0_INTERVAL
    BR0_V6_ELAPSED=$((BR0_V6_ELAPSED + BR0_INTERVAL))
done

log "Bridge interface: $BRIDGE_IFACE, IP: $BR0_IP, IPv6: ${BR0_IP_V6:-none}"
log "Node index (last octet): $LAST_OCTET"
log "  Router ID / VTEP IP: $ROUTER_ID"
log "  Loopback IPv6:       $LOOPBACK_V6"
log "  SRv6 source:         $SRV6_SOURCE"
log "  SRv6 locator:        $SRV6_PREFIX:$SRV6_NODE_ID::/48"
log "  Underlay IPv6:       $UNDERLAY_V6"
log "  ISIS NET:            $ISIS_NET"

#
# STEP 3: Configure underlay NIC (grout DPDK or kernel mode)
#
log_step "Configuring underlay NIC"

FRR_PID=$(frr_netns_pid)
if [[ -z "$FRR_PID" || "$FRR_PID" == "0" ]]; then
    error "Failed to get FRR container PID"
    exit_error "Cannot determine FRR namespace"
fi

log "FRR container PID: $FRR_PID"

if [[ -f "/run/grout-bind/$UNDERLAY_NIC" ]]; then
    #
    # Grout mode (masters): NIC was bound by grout-bind, use grcli to add port
    #
    log "Grout mode detected: /run/grout-bind/$UNDERLAY_NIC exists"
    UNDERLAY_PCI=$(cut -d' ' -f3 "/run/grout-bind/$UNDERLAY_NIC") ||
        exit_error "Failed to determine underlay NIC $UNDERLAY_NIC PCI address"

    grcli() {
        echo "+ grcli $*"
        podman exec grout grcli "$@"
    }

    log "Adding $UNDERLAY_NIC to grout (PCI: $UNDERLAY_PCI)..."
    grcli interface add port "$UNDERLAY_NIC" devargs "$UNDERLAY_PCI"

    log "$UNDERLAY_NIC configured via grout DPDK"
else
    #
    # Kernel mode (workers): move NIC to FRR namespace
    #
    log "Kernel mode: moving $UNDERLAY_NIC to FRR namespace"

    if ! ip link show "$UNDERLAY_NIC" >/dev/null 2>&1; then
        error "Host NIC $UNDERLAY_NIC not found"
        error "Available NICs:"
        ip -br link show | head -10 | while read line; do
            error "  $line"
        done
        exit_error "Host NIC $UNDERLAY_NIC not found"
    fi

    log "Found host NIC: $UNDERLAY_NIC"

    NIC_IP_CIDR=$(ip -4 addr show "$UNDERLAY_NIC" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || true)
    if [[ -z "$NIC_IP_CIDR" ]]; then
        log "WARNING: Host NIC $UNDERLAY_NIC does not have an IPv4 address configured"
    else
        log "Host NIC IPv4 address: $NIC_IP_CIDR (will be re-assigned after move)"
    fi

    NIC_IP6_CIDR=$(ip -6 addr show "$UNDERLAY_NIC" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+/\d+' | head -1 || true)
    if [[ -z "$NIC_IP6_CIDR" ]]; then
        log "WARNING: Host NIC $UNDERLAY_NIC does not have a global IPv6 address configured"
    else
        log "Host NIC IPv6 address: $NIC_IP6_CIDR (will be re-assigned after move)"
    fi

    # Move NIC to FRR namespace
    log "Moving $UNDERLAY_NIC to FRR namespace (PID: $FRR_PID)..."
    ip link set "$UNDERLAY_NIC" netns "$FRR_PID" 2>/dev/null || {
        log "WARNING: Failed to move $UNDERLAY_NIC to namespace (may already be there)"
    }

    # Bring up NIC in FRR namespace
    log "Bringing up $UNDERLAY_NIC in FRR namespace..."
    inns ip link set "$UNDERLAY_NIC" up 2>/dev/null || {
        log "WARNING: Failed to bring up $UNDERLAY_NIC in FRR namespace"
    }

    # Re-assign IPv4 address
    if [[ -n "$NIC_IP_CIDR" ]]; then
        log "Re-assigning IP $NIC_IP_CIDR to $UNDERLAY_NIC in FRR namespace..."
        inns ip addr add "$NIC_IP_CIDR" dev "$UNDERLAY_NIC" 2>/dev/null || {
            log "WARNING: Failed to assign IP (may already be configured)"
        }
        log "IP $NIC_IP_CIDR assigned to $UNDERLAY_NIC in FRR namespace"
    fi

    # Re-assign global IPv6 address
    if [[ -n "$NIC_IP6_CIDR" ]]; then
        log "Re-assigning IPv6 $NIC_IP6_CIDR to $UNDERLAY_NIC in FRR namespace..."
        inns ip -6 addr add "$NIC_IP6_CIDR" dev "$UNDERLAY_NIC" 2>/dev/null || {
            log "WARNING: Failed to assign IPv6 (may already be configured)"
        }
        log "IPv6 $NIC_IP6_CIDR assigned to $UNDERLAY_NIC in FRR namespace"
    fi

    log "Host NIC $UNDERLAY_NIC configured in FRR namespace (kernel mode)"
fi

# Add IPv6 address to underlay NIC for ISIS adjacency (both modes)
log "Adding IPv6 $UNDERLAY_V6/64 to $UNDERLAY_NIC in FRR namespace..."
inns ip -6 addr add "${UNDERLAY_V6}/64" dev "$UNDERLAY_NIC" 2>/dev/null || {
    log "WARNING: IPv6 address may already be configured"
}

#
# STEP 4: Configure loopback addresses and SRv6 sysctls in FRR namespace
#
log_step "Configuring loopback addresses and SRv6 in FRR namespace"

# IPv6 loopback for BGP peering
log "Adding IPv6 loopback $LOOPBACK_V6/128 to lo..."
inns ip -6 addr add "${LOOPBACK_V6}/128" dev lo 2>/dev/null || {
    log "WARNING: IPv6 loopback may already be configured"
}

# SRv6 source address on loopback
log "Adding SRv6 source $SRV6_SOURCE/128 to lo..."
inns ip -6 addr add "${SRV6_SOURCE}/128" dev lo 2>/dev/null || {
    log "WARNING: SRv6 source may already be configured"
}

inns ip link set lo up 2>/dev/null || true

# SRv6 sysctls
log "Setting SRv6 sysctls..."
inns sysctl -w net.ipv6.seg6_flowlabel=1 || {
    log "WARNING: Failed to set seg6_flowlabel (kernel support required)"
}
inns sysctl -w net.ipv6.conf.all.seg6_enabled=1 || {
    log "WARNING: Failed to enable seg6 (kernel support required)"
}
inns sysctl -w net.ipv6.conf.default.seg6_enabled=1 || true
inns sysctl -w "net.ipv6.conf.${UNDERLAY_NIC}.seg6_enabled=1" || true
inns sysctl -w net.ipv6.conf.lo.seg6_enabled=1 || true

# Create sr0 dummy interface for SRv6 SID installation in the kernel
log "Creating sr0 dummy interface for SRv6..."
inns ip link add sr0 type dummy 2>/dev/null || true
inns ip link set sr0 up || true
inns sysctl -w net.ipv6.conf.sr0.seg6_enabled=1 || true

# NOTE: vrf.strict_mode and rp_filter are set in setup-network.sh
# (after VRF creation, so the kernel module is loaded)

# IP forwarding
inns sysctl -w net.ipv4.ip_forward=1 || true
inns sysctl -w net.ipv6.conf.all.forwarding=1 || true

log "Loopback and SRv6 configuration complete"

#
# STEP 5: Save variables for config generation
#
log_step "Saving variables for config generation"

# Create directory if needed
mkdir -p "$(dirname "$VARS_FILE")"

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
BR0_IP_V6="${BR0_IP_V6:-}"
BR0_SUBNET="${BR0_IP%.*}.0/24"
BR0_SUBNET_V6="$(echo "$BR0_IP_V6" | sed 's/:[^:]*$//' | sed 's/:*$//')::/64"

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
