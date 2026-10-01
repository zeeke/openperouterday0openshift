#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "Usage: sudo $0" >&2
    exit 1
fi

libvirt=(virsh -c qemu:///system)
for name in master-0 master-1 master-2 worker-0 worker-1; do
    domain="openpe-$name"
    if "${libvirt[@]}" dominfo "$domain" >/dev/null 2>&1; then
        "${libvirt[@]}" destroy "$domain" >/dev/null 2>&1 || true
        "${libvirt[@]}" undefine "$domain"
    fi
done

docker rm -f openpe-tor >/dev/null 2>&1 || true
ip link del opelabtor >/dev/null 2>&1 || true

for network in openpe-underlay openpe-management; do
    if "${libvirt[@]}" net-info "$network" >/dev/null 2>&1; then
        "${libvirt[@]}" net-destroy "$network" >/dev/null 2>&1 || true
        "${libvirt[@]}" net-undefine "$network"
    fi
done

rm -rf /run/openpe-lab-tor /var/lib/libvirt/images/openpe-lab
echo 'OpenPERouter lab removed.'
