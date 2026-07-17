#!/bin/bash
set -euo pipefail

# setup-network.sh - Network infrastructure setup (flat / static routing)
#
# In flat mode there are no overlays (no VRF, no VXLAN, no L2VNI bridge).
# All network infrastructure is set up by setup-underlay.sh. This script
# is kept as a stub for systemd unit compatibility.
#
# Usage: Executed by setup-network.service after setup-underlay.service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

log "Flat mode: no overlay network to set up"
log "All infrastructure was configured by setup-underlay.sh"

exit 0
