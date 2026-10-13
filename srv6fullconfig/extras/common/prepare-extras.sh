#!/bin/bash
# Apply build-time settings to a copy of extras before compiling Butane.
set -euo pipefail

extras_dir="$1"

if [[ -v GROUT_DATAPATH ]]; then
    sed -i '/^Exec=/ s|$| --datapath=grout --grout-socket=/run/grout/grout.sock|' \
        "${extras_dir}/quadlets/controller.container"
    cat >> "${extras_dir}/quadlets/daemons" <<'EOF'

frr_global_options="-A 127.0.0.1 --log stdout"
zebra_options="-s 90000000 -M dplane_grout"
EOF
fi

default_image="quay.io/redhat-user-workloads/telco-5g-tenant/openperouter-operator-5-1:latest"
if [[ -v GROUT_DATAPATH ]]; then
    # Support for  Grout datapath is experimental.
    default_image="quay.io/apanatto/openperouter-operator:grout-dev-202611"
fi
image="${OPENPEROUTER_IMAGE:-${default_image}}"
sed -i "s|__OPENPEROUTER_IMAGE__|${image}|g" \
    "${extras_dir}"/quadlets/*.container "${extras_dir}"/config/pod-grout-reservation-*.yaml
