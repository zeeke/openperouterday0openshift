#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# all the butane sources in this directory.
#
# Usage: generate_machineconfigs.sh <output_dir>
#
#   output_dir  Directory where the MachineConfig YAML files are written
#
# Requires: butane, Python yq

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

output_dir="$1"
mkdir -p "${output_dir}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

# Prepare the shared files once, without modifying the source templates.
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
cp -a "${EXTRASDIR}/." "${tmpdir}/"
"${EXTRASDIR}/common/prepare-extras.sh" "${tmpdir}"

echo "==> Generating MachineConfig manifests into ${output_dir}..."
mkdir -p "${output_dir}"
# Remove manifests left by a previous datapath selection.
rm -f "${output_dir}"/*.yaml

# Compile every butane file. Grout files (*grout*) are only compiled when
# GROUT_DATAPATH is set.
for bu in "${SCRIPTDIR}"/*.bu; do
    name="$(basename "${bu}" .bu)"
    if [[ "${name}" == *grout* && ! -v GROUT_DATAPATH ]]; then
        continue
    fi
    echo "  ${name}.bu"
    butane --strict --files-dir="${tmpdir}" "${bu}" -o "${output_dir}/${name}.yaml"
done

if [[ -v GROUT_DATAPATH ]]; then
    cp "${SCRIPTDIR}/performance-profile-master.yaml" "${output_dir}/"
    cp "${SCRIPTDIR}/performance-profile-worker.yaml" "${output_dir}/"
fi

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

echo "==> MachineConfig manifests generated."
