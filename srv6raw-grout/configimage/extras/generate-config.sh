#!/bin/bash
set -euo pipefail

# generate-config.sh - Generate OpenPERouter FRR configuration (ISIS + SRv6)
#
# 1. Loads variables from vpn-setup.vars (written by dispatch)
# 2. Determines node role (EVPN route reflector vs client)
# 3. Selects the appropriate template (RR or client)
# 4. Renders configuration via envsubst
#
# Usage: Executed by systemd service generate-config.service

die() { echo "error: $*" >&2; exit 1; }

: ${TEMPLATE_DIR:=/etc/openperouter/templates}
: ${CONFIG_OUTPUT:=/var/lib/openperouter/configs/openpe_evpn.yaml}

# Load environment configuration
set -a

source /etc/openperouter/openperouter.env
source /var/lib/openperouter/vpn-setup.vars

: ${BGP_AS:=65500}
: ${RR_NODE_IDX:=2}
: ${SRV6_GATEWAY:=fc00:0:20::1}
: ${VRF_NAME:=red}
: ${L2_VNI:=210}
: ${L2_GATEWAY_IP:=192.168.110.1/24}
: ${L2_GATEWAY_IP_V6:=fd00:110::1/64}

set +a

echo "NODE_NAME=$NODE_NAME LAST_OCTET=$LAST_OCTET"

# Determine role and select template
if [ "$LAST_OCTET" == "$RR_NODE_IDX" ]; then
	echo "This node is the EVPN/VPN Route Reflector (idx=$LAST_OCTET)"
	CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_evpn.yaml_rr.template"
	EVPN_LISTEN_RANGE="${EVPN_LISTEN_RANGE:-fc00::/16}"
	export EVPN_LISTEN_RANGE
else
	echo "This node is an EVPN/VPN client (idx=$LAST_OCTET, RR=$RR_NODE_IDX)"
	CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_evpn.yaml.template"
	RR_LOOPBACK="fc00:0:${RR_NODE_IDX}::1"
	export RR_LOOPBACK
fi

[[ -f "$CONFIG_TEMPLATE" ]] || die "Template not found: $CONFIG_TEMPLATE"

# Render configuration
mkdir -p "$(dirname "$CONFIG_OUTPUT")"
envsubst < "$CONFIG_TEMPLATE" > "$CONFIG_OUTPUT" || die "Failed to render template"

echo "Configuration written to $CONFIG_OUTPUT"

# Validate
for section in "rawfrrconfigs:" "router isis PE" "segment-routing" "router bgp"; do
	grep -q "$section" "$CONFIG_OUTPUT" \
		|| die "Missing required section: $section"
done

grep -q "${ROUTER_ID}" "$CONFIG_OUTPUT" \
	|| die "Missing Router ID in generated config"

echo "Configuration validated"
