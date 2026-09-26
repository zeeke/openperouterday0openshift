#!/bin/bash
# Apply build-time settings to a copy of extras before compiling Butane.
set -euo pipefail

extras_dir="$1"

if [[ -v GROUT_DATAPATH ]]; then
    case "${GROUT_DATAPATH}" in
        hw|tap) ;;
        *) echo "ERROR: GROUT_DATAPATH must be hw or tap" >&2; exit 1 ;;
    esac
fi

if [[ -n "${GROUT_DATAPATH:-}" ]]; then
    sed -i '/^Exec=/ s|$| --datapath=grout --grout-socket=/run/grout/grout.sock|' \
        "${extras_dir}/quadlets/controller.container"
    cat >> "${extras_dir}/quadlets/daemons" <<'EOF'

frr_global_options="-A 127.0.0.1 --log stdout"
zebra_options="-s 90000000 -M dplane_grout"
EOF
fi

if [[ "${GROUT_DATAPATH:-}" == hw ]]; then
    cp "${extras_dir}/config/openpe_master-hw.yaml" "${extras_dir}/config/openpe_master.yaml"
    cp "${extras_dir}/config/openpe_worker-hw.yaml" "${extras_dir}/config/openpe_worker.yaml"
fi

image="${OPENPEROUTER_IMAGE:-quay.io/redhat-user-workloads/telco-5g-tenant/openperouter-operator-edge-5-0:latest}"
sed -i "s|__OPENPEROUTER_IMAGE__|${image}|g" \
    "${extras_dir}"/quadlets/*.container "${extras_dir}/config/workload-pod.yaml"
