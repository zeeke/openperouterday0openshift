#!/bin/bash
# generate_config_image.sh - Build the agent config-image ISO (rawconfig mode).
#
# Compiles MachineConfig manifests from rawconfig butane sources, then runs
# `openshift-install agent create config-image` to produce the config-image
# ISO that the appliance mounts at first boot.
#
# Usage: generate_config_image.sh <pull_secret_file> [config_image_dir]
#
#   pull_secret_file  Path to the pull secret JSON file (required)
#   config_image_dir  Working directory for config-image generation
#                     (default: ./configimage)
#
# The ISO is written to <config_image_dir>/agentconfig.noarch.iso
#
# Requires: butane, jq, yq

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE_CACHE="${SCRIPTDIR}/../appliance/cache"

pull_secret_file="${1:-}"

if [[ -z "${pull_secret_file}" || ! -f "${pull_secret_file}" ]]; then
    echo "ERROR: Pull secret file not found: ${pull_secret_file:-<not provided>}"
    echo "Usage: $0 <pull_secret_file> [config_image_dir]"
    exit 1
fi

config_image_dir="$(realpath "${2:-${SCRIPTDIR}/configimage}")"

# Use openshift-install from the appliance cache
openshift_install=$(find "${APPLIANCE_CACHE}" -name 'openshift-install' -type f 2>/dev/null | head -1)
if [[ -z "${openshift_install}" || ! -x "${openshift_install}" ]]; then
    echo "ERROR: openshift-install not found in ${APPLIANCE_CACHE}. Build the appliance first."
    exit 1
fi
echo "Using: ${openshift_install}"

# ============================================================
# Prepare config-image work directory
# ============================================================
mkdir -p "${config_image_dir}"

# Generate install-config.yaml from base template with injected pull secret
pull_secret="$(jq -c . "${pull_secret_file}")"
yq -y ".pullSecret = $(echo "${pull_secret}" | jq -R .)" \
    "${SCRIPTDIR}/install-config.yaml.base" > "${config_image_dir}/install-config.yaml"

cp "${SCRIPTDIR}/agent-config.yaml" "${config_image_dir}/"

# Remove namespace fields that cause strict diff failures
# in the appliance's load-config-iso.sh
sed -i '/^  namespace:/d' "${config_image_dir}/agent-config.yaml"
sed -i '/^  namespace:/d' "${config_image_dir}/install-config.yaml"

# ============================================================
# Generate MachineConfig manifests from rawconfig butane sources
# ============================================================
extra_manifests_dir="${config_image_dir}/openshift"

"${SCRIPTDIR}/generate_machineconfigs.sh" "${extra_manifests_dir}"

# ============================================================
# Create the config-image ISO
# ============================================================
echo "==> Creating config-image ISO..."

"${openshift_install}" --log-level=debug --dir="${config_image_dir}" agent create config-image

# Copy auth files alongside the ISO for wait-for access
if [[ -d "${config_image_dir}/auth" ]]; then
    echo "  Auth files available at ${config_image_dir}/auth/"
fi

echo "==> Done: ${config_image_dir}/agentconfig.noarch.iso"
