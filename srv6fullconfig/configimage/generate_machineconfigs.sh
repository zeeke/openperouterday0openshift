#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# all the butane sources in this directory.
#
# Usage: generate_machineconfigs.sh <output_dir>
#
#   output_dir  Directory where the MachineConfig YAML files are written
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

output_dir="$1"
mkdir -p "${output_dir}"

if ! command -v butane &>/dev/null; then
    echo "ERROR: butane is required but not found. Install with: sudo dnf install butane"
    exit 1
fi

echo "==> Generating MachineConfig manifests into ${output_dir}..."

# Compile every butane file.
for bu in "${SCRIPTDIR}"/*.bu; do
    name="$(basename "${bu}" .bu)"
    echo "  ${name}.bu"
    butane --strict --files-dir="${EXTRASDIR}" "${bu}" -o "${output_dir}/${name}.yaml"
done

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

echo "==> MachineConfig manifests generated."
