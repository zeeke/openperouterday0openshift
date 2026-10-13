#!/usr/bin/env bash
set -euo pipefail

lab_dir=$(cd "$(dirname "$0")" && pwd)
bash -n "$lab_dir/lab-up.sh" "$lab_dir/lab-down.sh" \
    "$lab_dir/externalfrr/run_frr.sh" "$lab_dir/externalfrr/cleanup.sh"
dnsmasq --test --conf-file="$lab_dir/externalfrr/config/dnsmasq.conf"
[[ $(grep -c '^        - 10.100.0.1$' "$lab_dir/configimage/agent-config.yaml") -eq 5 ]]
