#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter, registry).
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

compile_bu() {
    local bu="$1" prefix="$2" name="$3"
    if [[ ! -f "${SCRIPTDIR}/${bu}" ]]; then
        return
    fi
    for role in master worker; do
        local out="${output_dir}/${prefix}-${role}-${name}.yaml"
        echo "  ${bu} -> $(basename "${out}")"
        butane --files-dir="${EXTRASDIR}" "${SCRIPTDIR}/${bu}" \
            | sed "s/role: master/role: ${role}/;s/name: ${prefix}-master-/name: ${prefix}-${role}-/" \
            > "${out}"
    done
}

echo "==> Generating MachineConfig manifests into ${output_dir}..."

compile_bu openperouter.bu 99 openperouter
compile_bu registry.bu 01 registry

echo "==> MachineConfig manifests generated."
