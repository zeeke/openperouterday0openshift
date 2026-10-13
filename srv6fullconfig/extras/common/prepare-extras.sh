#!/bin/bash
# Apply build-time settings to a copy of extras before compiling Butane.
set -euo pipefail

extras_dir="$1"

image="${OPENPEROUTER_IMAGE:-quay.io/redhat-user-workloads/telco-5g-tenant/openperouter-operator-5-1:latest}"
sed -i "s|__OPENPEROUTER_IMAGE__|${image}|g" \
    "${extras_dir}"/quadlets/*.container
