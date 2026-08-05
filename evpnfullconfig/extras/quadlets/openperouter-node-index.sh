#!/usr/bin/env bash
# Extract the last octet from the br0 bridge IP and write it as nodeIndex
# in the openperouter node-config.yaml.

set -euo pipefail

BRIDGE_NAME="${1:-br0}"
CONFIG_PATH="/var/lib/openperouter/node-config.yaml"
MAX_RETRIES=60

get_bridge_ip() {
  ip -4 -o addr show dev "${BRIDGE_NAME}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true
}

# Wait for the bridge to get an IPv4 address
BRIDGE_IP=""
for (( i=1; i<=MAX_RETRIES; i++ )); do
  BRIDGE_IP=$(get_bridge_ip)
  if [ -n "${BRIDGE_IP}" ]; then
    break
  fi
  echo "Waiting for ${BRIDGE_NAME} to get an IPv4 address (attempt ${i}/${MAX_RETRIES})..."
  sleep 2
done

if [ -z "${BRIDGE_IP}" ]; then
  echo "ERROR: No IPv4 address found on ${BRIDGE_NAME} after ${MAX_RETRIES} attempts" >&2
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
