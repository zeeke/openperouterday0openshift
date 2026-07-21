#!/usr/bin/env bash
# Extract the last octet from the host VF or br-ex IP and write it as
# nodeIndex in the openperouter node-config.yaml.

set -euo pipefail

MAX_RETRIES=60

source /etc/openperouter/vpn-setup.env

get_host_ip() {
  for iface in "$HOST_VF" br-ex; do
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
      | awk '{print $4}' | cut -d/ -f1 | head -1
  done | head -1
}

HOST_IP=""
for (( i=1; i<=MAX_RETRIES; i++ )); do
  HOST_IP=$(get_host_ip) || true
  if [[ -n "$HOST_IP" ]]; then
    break
  fi
  echo "Waiting for host IP on $HOST_VF (attempt ${i}/${MAX_RETRIES})..."
  sleep 2
done

if [[ -z "$HOST_IP" ]]; then
  echo "ERROR: No IPv4 address found after ${MAX_RETRIES} attempts" >&2
  exit 1
fi

NODE_INDEX="${HOST_IP##*.}"

echo "Setting nodeIndex to ${NODE_INDEX} (from IP ${HOST_IP})"

mkdir -p /var/lib/openperouter
cat > /var/lib/openperouter/node-config.yaml <<EOF
nodeIndex: ${NODE_INDEX}
logLevel: info
EOF
