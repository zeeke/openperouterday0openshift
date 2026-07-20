#!/usr/bin/env bash
# Extract the last octet from the host VF or br-ex IP and write it as
# nodeIndex in the openperouter node-config.yaml.

set -euo pipefail

HOST_VF="${1:-eno12399v2}}"
CONFIG_PATH="/var/lib/openperouter/node-config.yaml"
MAX_RETRIES=60

# Wait for an IPv4 address on either the VF or br-ex
BRIDGE_IP=""
BRIDGE_NAME=""
for (( i=1; i<=MAX_RETRIES; i++ )); do
  for iface in "$HOST_VF" br-ex; do
    BRIDGE_IP=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
    if [ -n "${BRIDGE_IP}" ]; then
      BRIDGE_NAME="$iface"
      break 2
    fi
  done
  echo "Waiting for ${HOST_VF}/br-ex to get an IPv4 address (attempt ${i}/${MAX_RETRIES})..."
  sleep 2
done

if [ -z "${BRIDGE_IP}" ]; then
  echo "ERROR: No IPv4 address found on ${HOST_VF} or br-ex after ${MAX_RETRIES} attempts" >&2
  exit 1
fi

# Extract the last octet
NODE_INDEX="${BRIDGE_IP##*.}"

echo "Setting nodeIndex to ${NODE_INDEX} (from ${BRIDGE_NAME} IP ${BRIDGE_IP})"

mkdir -p "$(dirname "${CONFIG_PATH}")"
cat > "${CONFIG_PATH}" <<EOF
nodeIndex: ${NODE_INDEX}
logLevel: info
EOF
