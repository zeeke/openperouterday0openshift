#!/usr/bin/env bash
# Extract the last octet from the br0 bridge IP and write it as nodeIndex
# in the openperouter node-config.yaml.

set -euo pipefail

source /etc/openperouter/openperouter.env


CONFIG_PATH="/var/lib/openperouter/node-config.yaml"

echo "Determining nodeIndex from hostname..."
echo "NODE_INDEXES: $NODE_INDEXES"

NODE_NAME=""
NODE_INDEX=""
until [[ -n "$NODE_INDEX" ]]; do
  NODE_NAME="$(hostname)"
  NODE_INDEX=$(echo "$NODE_INDEXES" | awk -v node="$NODE_NAME" '$1 == node { print $2 }')
  if [[ -z "$NODE_INDEX" ]]; then
    echo "hostname '$NODE_NAME' not found in NODE_INDEXES, retrying in 5s..."
    sleep 5
  fi
done

echo "Setting nodeIndex to ${NODE_INDEX} (from ${NODE_NAME})"

mkdir -p "$(dirname "${CONFIG_PATH}")"
cat > "${CONFIG_PATH}" <<EOF
nodeIndex:
  index: $NODE_INDEX
logLevel: debug
EOF

# Override the default config with a node-specific config if it exists
if [ -f "/var/lib/openperouter/configs/${NODE_NAME}.yaml" ]; then
  cp "/var/lib/openperouter/configs/${NODE_NAME}.yaml" "/var/lib/openperouter/configs/openpe_config.yaml"
fi

# TODO: find a better place for this
modprobe vfio-pci
