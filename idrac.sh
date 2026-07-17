#!/bin/bash
set -euo pipefail

# idrac-boot.sh - Boot a Dell server from virtual media ISOs via iDRAC
# Redfish API.
#
# Usage: idrac-boot.sh <idrac_host> <url> [url...]
#
#   idrac_host   iDRAC hostname or IP
#   url          HTTP URL(s) of ISO images to mount as virtual media
#
# The ISOs must be served over HTTP/1.1 (e.g. nginx). iDRAC does not
# support HTTP/1.0 (python http.server) or local file paths.
#
# Environment:
#   IDRAC_USER   iDRAC username (default: root)
#   IDRAC_PASS   iDRAC password (default: calvin)
#
# Requires: curl, jq

idrac_host="${1:-}"
shift || true

if [[ -z "${idrac_host}" || $# -eq 0 ]]; then
	echo "Usage: $0 <idrac_host> <url> [url...]"
	echo ""
	echo "Example:"
	echo "  $0 192.168.132.150 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso"
	exit 1
fi

IDRAC_USER="${IDRAC_USER:-root}"
IDRAC_PASS="${IDRAC_PASS:-Thok7Zi90deJA8r0wEPr}"

IDRAC="https://${idrac_host}"
VMEDIA="${IDRAC}/redfish/v1/Systems/System.Embedded.1/VirtualMedia"

curl() {
	command curl -sfkL -u "${IDRAC_USER}:${IDRAC_PASS}" "$@"
}
export -f curl

# Discover available virtual media slots
slots=$(curl "${VMEDIA}" | jq -r '.Members[]."@odata.id"' | grep -oP '\d+$')
slot_count=$(echo "${slots}" | wc -l)

if [[ $# -gt ${slot_count} ]]; then
	echo "ERROR: ${#} ISOs requested but only ${slot_count} virtual media slots available"
	exit 1
fi

# Eject any existing virtual media
echo "==> Ejecting existing virtual media..."
for slot in ${slots}; do
	inserted=$(curl "${VMEDIA}/${slot}" | jq -r '.Inserted')
	if [[ "${inserted}" == "true" ]]; then
		curl -X POST \
			"${VMEDIA}/${slot}/Actions/VirtualMedia.EjectMedia" \
			-H 'Content-Type: application/json' -d '{}'
		echo "  Ejected slot ${slot}"
	fi
done

# Insert ISOs
slot_idx=0
for url in "$@"; do
	slot=$(echo "${slots}" | sed -n "$((slot_idx + 1))p")
	echo "==> Inserting ${url} on slot ${slot}..."
	curl -X POST \
		"${VMEDIA}/${slot}/Actions/VirtualMedia.InsertMedia" \
		-H 'Content-Type: application/json' \
		-d "{\"Image\": \"${url}\"}"
	slot_idx=$((slot_idx + 1))
done

# Verify
echo "==> Verifying virtual media..."
for slot in ${slots}; do
	curl "${VMEDIA}/${slot}" | jq '{Id, Image, Inserted}'
done

# Set persistent Hdd boot so that subsequent reboots during install go
# to disk instead of falling through to the still-mounted virtual media.
# Then set a one-time Cd override for the initial ISO boot.
echo "==> Setting persistent Hdd boot + one-time Cd override..."
curl -X PATCH \
	"${IDRAC}/redfish/v1/Systems/System.Embedded.1" \
	-H 'Content-Type: application/json' \
	-d '{"Boot": {"BootSourceOverrideTarget": "Hdd", "BootSourceOverrideEnabled": "Continuous"}}' \
	-o /dev/null
curl -X PATCH \
	"${IDRAC}/redfish/v1/Systems/System.Embedded.1" \
	-H 'Content-Type: application/json' \
	-d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}' \
	-o /dev/null

echo "==> Rebooting server..."
curl -X POST \
	"${IDRAC}/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset" \
	-H 'Content-Type: application/json' \
	-d '{"ResetType": "ForceRestart"}' \
	-o /dev/null

echo "==> Done. Server is booting from virtual media."

