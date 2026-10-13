#!/usr/bin/env bash
set -euo pipefail

# Clean up the external FRR remotepe container and all created interfaces.
#
# Usage:
#   ./cleanup.sh

CONTAINER_NAME="externalfrr"
VRF_NAME="${VRF_NAME:-red}"
DNS_PID_FILE="/run/dnsmasq-vrf-${VRF_NAME}.pid"
VTEP_LO="lo-vtep"
LO_NAME="lo-extra"
ISIS_IFACE="${ISIS_IFACE:-}"

echo "Cleaning up external FRR (remotepe)..."

# Stop DNS forwarder
if [ -f "${DNS_PID_FILE}" ] && sudo kill -0 "$(cat "${DNS_PID_FILE}")" 2>/dev/null; then
    echo "  Stopping DNS forwarder (PID $(cat "${DNS_PID_FILE}"))..."
    sudo kill "$(cat "${DNS_PID_FILE}")"
    sudo rm -f "${DNS_PID_FILE}"
else
    echo "  DNS forwarder not running, skipping"
    sudo rm -f "${DNS_PID_FILE}"
fi

# Stop and remove FRR container
if sudo podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Stopping container '${CONTAINER_NAME}'..."
    sudo podman rm -f "${CONTAINER_NAME}"
else
    echo "  Container '${CONTAINER_NAME}' not found, skipping"
fi

# Remove extra loopback (DNS)
if ip link show "${LO_NAME}" &>/dev/null; then
    echo "  Removing loopback ${LO_NAME}..."
    sudo ip link set "${LO_NAME}" down
    sudo ip link del "${LO_NAME}"
else
    echo "  Loopback ${LO_NAME} not found, skipping"
fi

# Remove VRF loopback (lored)
if ip link show "lored" &>/dev/null; then
    echo "  Removing VRF loopback lored..."
    sudo ip link set lored down
    sudo ip link del lored
else
    echo "  VRF loopback lored not found, skipping"
fi

# Remove VTEP loopback interface
if ip link show "${VTEP_LO}" &>/dev/null; then
    echo "  Removing loopback ${VTEP_LO}..."
    sudo ip link set "${VTEP_LO}" down
    sudo ip link del "${VTEP_LO}"
else
    echo "  Loopback ${VTEP_LO} not found, skipping"
fi

# Remove VRF
if ip link show "${VRF_NAME}" &>/dev/null; then
    echo "  Removing VRF ${VRF_NAME}..."
    sudo firewall-cmd --zone=trusted --remove-interface="${VRF_NAME}" 2>/dev/null || true
    sudo ip link set "${VRF_NAME}" down
    sudo ip link del "${VRF_NAME}"
else
    echo "  VRF ${VRF_NAME} not found, skipping"
fi

echo "Done."
