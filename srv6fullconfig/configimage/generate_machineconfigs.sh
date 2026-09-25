#!/bin/bash
# generate_machineconfigs.sh - Compile MachineConfig manifests from
# butane sources (openperouter-master/worker, dns, registry, grout).
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

# The first two appliance images are for the kernel and grout datapaths.
image_index=0
if [[ -n "${GROUT_DATAPATH:-}" ]]; then
    image_index=1
    sed -i '/^Exec=/ s|$| --datapath=grout --grout-socket=/run/grout/grout.sock|' \
        "${tmpdir}/quadlets/controller.container"
fi

image=$(yq -er ".additionalImages[${image_index}].name" \
    "${SCRIPTDIR}/../appliance/appliance-config.yaml.base")
sed -i "s|__OPENPEROUTER_IMAGE__|${image}|g" \
    "${tmpdir}"/quadlets/*.container "${tmpdir}/config/workload-pod.yaml"

echo "==> Generating MachineConfig manifests into ${output_dir}..."
mkdir -p "${output_dir}"
# Remove optional manifests left by a previous datapath selection.
rm -f "${output_dir}"/9[78]-*-grout*.yaml "${output_dir}/performance-profile.yaml"

compile() {
    echo "  $1 -> $2"
    butane --strict --files-dir="${tmpdir}" "${SCRIPTDIR}/$1" -o "${output_dir}/$2"
}

compile openperouter-master.bu 99-master-openperouter.yaml
compile openperouter-worker.bu 99-worker-openperouter.yaml
compile registry.bu 01-master-registry.yaml
compile registry-worker.bu 01-worker-registry.yaml
compile if-mtu.bu 99-master-if-mtu.yaml
compile if-mtu-worker.bu 99-worker-if-mtu.yaml

if [[ -n "${GROUT_DATAPATH:-}" ]]; then
    compile openperouter-master-grout.bu 98-master-openperouter-grout.yaml
    compile openperouter-worker-grout.bu 98-worker-openperouter-grout.yaml
    compile grout-kargs-master.bu 96-master-grout-kargs.yaml
    compile grout-kargs-worker.bu 96-worker-grout-kargs.yaml
    echo "  performance-profile.yaml"
    cp "${SCRIPTDIR}/performance-profile.yaml" "${output_dir}/"
    
    cat >> "${tmpdir}/quadlets/daemons" <<'EOF'

frr_global_options="-A 127.0.0.1 --log stdout"
zebra_options="-s 90000000 -M dplane_grout"
EOF

fi

if [[ "${GROUT_DATAPATH:-}" == hw ]]; then
    compile openperouter-master-grout-hw.bu 97-master-openperouter-grout-hw.yaml
    compile openperouter-worker-grout-hw.bu 97-worker-openperouter-grout-hw.yaml

    cp "${tmpdir}/config/openpe_master-hw.yaml" "${tmpdir}/config/openpe_master.yaml"
    cp "${tmpdir}/config/openpe_worker-hw.yaml" "${tmpdir}/config/openpe_worker.yaml"
fi

echo "  set-cluster-mtu.yaml"
cp "${EXTRASDIR}/config/set-cluster-mtu.yaml" "${output_dir}/set-cluster-mtu.yaml"

echo "==> MachineConfig manifests generated."
