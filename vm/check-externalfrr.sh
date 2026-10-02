#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$repo_dir/vm/lab-up.sh" "$repo_dir/vm/lab-down.sh" \
    "$repo_dir/vm/externalfrr/run_frr.sh" "$repo_dir/vm/externalfrr/cleanup.sh"
dnsmasq --test --conf-file="$repo_dir/vm/externalfrr/config/dnsmasq.conf"
[[ $(grep -c '^        - 10.100.0.1$' "$repo_dir/srv6fullconfig/configimage/agent-config.yaml") -eq 5 ]]
