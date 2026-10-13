#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "Usage: sudo $0" >&2
    exit 1
fi

libvirt=(virsh -c qemu:///system)
work_dir=/var/lib/libvirt/images/openpe-lab
for name in master-0 master-1 master-2 worker-0 worker-1; do
    domain="openpe-$name"
    if "${libvirt[@]}" dominfo "$domain" >/dev/null 2>&1; then
        "${libvirt[@]}" destroy "$domain" >/dev/null 2>&1 || true
        "${libvirt[@]}" undefine "$domain"
    fi
    pf_domain="pf-$name"
    if "${libvirt[@]}" net-info "$pf_domain" >/dev/null 2>&1; then
        "${libvirt[@]}" net-destroy "$pf_domain" >/dev/null 2>&1 || true
        "${libvirt[@]}" net-undefine "$pf_domain"
    fi
done

# The upstream cleanup script names lo-vtep, but run_frr.sh creates lo-und.
if [[ -d $work_dir/externalfrr ]]; then
    for entry in dnsmasq:/run/dnsmasq-vrf-red.pid chronyd:/run/chronyd-vrf.pid; do
        service=${entry%%:*}
        pidfile=${entry#*:}
        if [[ -f $pidfile ]]; then
            pid=$(< "$pidfile")
            if [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/comm ]] &&
                [[ $(< "/proc/$pid/comm") == "$service" ]]; then
                kill "$pid" || true
            fi
            rm -f "$pidfile"
        fi
    done
    podman rm -f externalfrr >/dev/null 2>&1 || true
    nft delete table inet srv6-vrf-notrack >/dev/null 2>&1 || true
    firewall-cmd --zone=trusted --remove-interface=red >/dev/null 2>&1 || true
    for link in lo-extra lored lo-und red; do
        ip link del "$link" >/dev/null 2>&1 || true
    done
    if [[ -f $work_dir/sysctls ]]; then
        while IFS= read -r setting; do sysctl -qw "$setting" || true; done < "$work_dir/sysctls"
    fi
fi
docker rm -f openpe-externalfrr openpe-tor >/dev/null 2>&1 || true
ip link del opelabtor >/dev/null 2>&1 || true

for network in openpe-underlay openpe-management; do
    if "${libvirt[@]}" net-info "$network" >/dev/null 2>&1; then
        "${libvirt[@]}" net-destroy "$network" >/dev/null 2>&1 || true
        "${libvirt[@]}" net-undefine "$network"
    fi
done

rm -rf /run/openpe-lab-externalfrr /run/openpe-lab-tor "$work_dir"
echo 'OpenPERouter lab removed.'
