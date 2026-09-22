#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter-master/worker, dns, registry).
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

if [[ -f "${SCRIPTDIR}/openperouter-master.bu" ]]; then
    echo "  openperouter-master.bu -> 99-master-openperouter.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/openperouter-master.bu" \
        -o "${output_dir}/99-master-openperouter.yaml"
fi

if [[ -f "${SCRIPTDIR}/openperouter-worker.bu" ]]; then
    echo "  openperouter-worker.bu -> 99-worker-openperouter.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/openperouter-worker.bu" \
        -o "${output_dir}/99-worker-openperouter.yaml"
fi

if [[ -f "${SCRIPTDIR}/registry.bu" ]]; then
    echo "  registry.bu -> 01-master-registry.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/registry.bu" \
        -o "${output_dir}/01-master-registry.yaml"
fi

if [[ -f "${SCRIPTDIR}/registry-worker.bu" ]]; then
    echo "  registry-worker.bu -> 01-worker-registry.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/registry-worker.bu" \
        -o "${output_dir}/01-worker-registry.yaml"
fi

if [[ -f "${SCRIPTDIR}/if-mtu.bu" ]]; then
    echo "  if-mtu.bu -> 01-master-if-mtu.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/if-mtu.bu" \
        -o "${output_dir}/99-master-if-mtu.yaml"
fi

if [[ -f "${SCRIPTDIR}/if-mtu-worker.bu" ]]; then
    echo "  if-mtu-worker.bu -> 01-worker-if-mtu.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/if-mtu-worker.bu" \
        -o "${output_dir}/99-worker-if-mtu.yaml"
fi

# TODO-GROUT: if GROUT_DATAPATH_HW_ACCELERATION
if [[ -f "${SCRIPTDIR}/grout-kargs-master.bu" ]]; then
    echo "  grout-kargs-master.bu -> 98-master-grout-kargs.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/grout-kargs-master.bu" \
        -o "${output_dir}/98-master-grout-kargs.yaml"
fi

# TODO-GROUT: if GROUT_DATAPATH_HW_ACCELERATION
if [[ -f "${SCRIPTDIR}/grout-kargs-worker.bu" ]]; then
    echo "  grout-kargs-worker.bu -> 98-worker-grout-kargs.yaml"
    butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/grout-kargs-worker.bu" \
        -o "${output_dir}/98-worker-grout-kargs.yaml"
fi

# TODO-GROUT: if GROUT_DATAPATH_HW_ACCELERATION
if [[ -f "${SCRIPTDIR}/performance-profile.yaml" ]]; then
    echo "  performance-profile.yaml"
    cp "${SCRIPTDIR}/performance-profile.yaml" "${output_dir}/"
fi

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

echo "==> MachineConfig manifests generated."
