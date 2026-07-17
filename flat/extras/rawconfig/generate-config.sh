#!/bin/bash
set -euo pipefail

# generate-config.sh - Generate OpenPERouter FRR configuration (flat / ISIS routing)
#
# This script:
# 1. Loads variables from setup-underlay.sh
# 2. Renders the static route FRR configuration template via envsubst
#
# Usage: Executed by systemd service generate-config.service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

UNDERLAY_NIC="${UNDERLAY_NIC:-ens1f0v0}"

VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/etc/openperouter/templates}"
CONFIG_OUTPUT="${CONFIG_OUTPUT:-/var/lib/openperouter/configs/openpe_config.yaml}"

log "Starting configuration generation (flat / ISIS routing mode)"

#
# STEP 1: Load variables from setup-underlay.sh
#
log_step "Loading variables from underlay setup"

if [[ ! -f "$VARS_FILE" ]]; then
    error "Variables file not found: $VARS_FILE"
    error "setup-underlay.service must run first"
    exit_error "Missing variables file"
fi

source "$VARS_FILE"

log "Loaded variables from $VARS_FILE"
log "  NODE_NAME=$NODE_NAME, LAST_OCTET=$LAST_OCTET"
log "  ROUTER_ID=$ROUTER_ID, ISIS_NET=$ISIS_NET"
log "  TRUNK_VLAN=$TRUNK_VLAN, GATEWAY_IP=$GATEWAY_IP, GATEWAY_IP_V6=$GATEWAY_IP_V6"

#
# STEP 2: Select template and render
#
log_step "Rendering configuration from template"

CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_flat.yaml.template"

if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
    error "Configuration template not found: $CONFIG_TEMPLATE"
    exit_error "Missing configuration template"
fi

log "Using template: $CONFIG_TEMPLATE"

mkdir -p "$(dirname "$CONFIG_OUTPUT")"

export NODE_NAME UNDERLAY_NIC TRUNK_VLAN
export ROUTER_ID ISIS_NET
export GATEWAY_IP GATEWAY_IP_V6

envsubst < "$CONFIG_TEMPLATE" > "$CONFIG_OUTPUT" || {
    error "Failed to render configuration template"
    exit_error "Template rendering failed"
}

log "Configuration written to: $CONFIG_OUTPUT"

#
# STEP 3: Validate generated configuration
#
log_step "Validating generated configuration"

for section in "rawfrrconfigs:" "router isis" "ip forwarding"; do
    if ! grep -q "$section" "$CONFIG_OUTPUT"; then
        error "Generated config is missing required section: $section"
        exit_error "Invalid generated configuration"
    fi
done

log "Configuration validated successfully"

log "Configuration preview (first 20 lines):"
head -20 "$CONFIG_OUTPUT" | while IFS= read -r line; do log "  $line"; done
log "  ..."

exit_success "Configuration generation completed successfully"
