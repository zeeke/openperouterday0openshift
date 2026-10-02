#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./vm/lab-up.sh /path/to/appliance.iso /path/to/agentconfig.noarch.iso
# The ISO pair must be built from srv6fullconfig with its current agent-config.yaml.

if (( EUID != 0 )) || (( $# != 2 )); then
    echo "Usage: sudo $0 <appliance.iso> <config-image.iso>" >&2
    exit 1
fi

for command in podman sudo nft dnsmasq chronyd virsh qemu-img ip sysctl envsubst; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -e /dev/kvm ]] || { echo 'KVM is required' >&2; exit 1; }

appliance=$(realpath "$1")
config_image=$(realpath "$2")
[[ -f $appliance && -f $config_image ]] || { echo 'Both ISO files must exist' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work_dir=/var/lib/libvirt/images/openpe-lab
libvirt=(virsh -c qemu:///system)
names=(master-0 master-1 master-2 worker-0 worker-1)
underlay_macs=(
    00:fb:7c:be:b9:43
    00:fb:7c:be:b9:46
    00:fb:7c:be:b9:49
    00:fb:7c:be:b9:4c
    00:fb:7c:be:b9:4f
)
idle_macs=(
    00:fb:7c:be:b9:44
    00:fb:7c:be:b9:47
    00:fb:7c:be:b9:4a
    00:fb:7c:be:b9:4d
    00:fb:7c:be:b9:50
)
management_macs=(
    00:fb:7c:be:b9:45
    00:fb:7c:be:b9:48
    00:fb:7c:be:b9:4b
    00:fb:7c:be:b9:4e
    00:fb:7c:be:b9:51
)
vm_memory_mib=${VM_MEMORY_MIB:-16384}
vm_vcpus=${VM_VCPUS:-8}
vm_disk_gb=${VM_DISK_GB:-220}

for value in "$vm_memory_mib" "$vm_vcpus" "$vm_disk_gb"; do
    [[ $value =~ ^[1-9][0-9]*$ ]] || { echo 'VM sizing must be positive integers' >&2; exit 1; }
done
(( vm_disk_gb >= 200 )) || { echo 'VM_DISK_GB must be at least 200' >&2; exit 1; }
"${libvirt[@]}" list --all >/dev/null || { echo 'Cannot connect to system libvirt' >&2; exit 1; }
podman info >/dev/null || { echo 'Cannot connect to Podman' >&2; exit 1; }

[[ ! -e $work_dir ]] || { echo 'Lab files already exist; run lab-down.sh first' >&2; exit 1; }
for link in opelabu opelabm opelabtor red lo-und lored lo-extra; do
    if ip link show "$link" >/dev/null 2>&1; then
        echo "Network link already exists: $link" >&2
        exit 1
    fi
done
for network in openpe-underlay openpe-management; do
    if "${libvirt[@]}" net-info "$network" >/dev/null 2>&1; then
        echo "Libvirt network already exists: $network" >&2
        exit 1
    fi
done
for name in "${names[@]}"; do
    if "${libvirt[@]}" dominfo "openpe-$name" >/dev/null 2>&1; then
        echo "Libvirt domain already exists: openpe-$name" >&2
        exit 1
    fi
done
if podman container exists externalfrr; then
    echo 'Podman container already exists: externalfrr' >&2
    exit 1
fi
if nft list table inet srv6-vrf-notrack >/dev/null 2>&1; then
    echo 'nftables table already exists: srv6-vrf-notrack' >&2
    exit 1
fi

# A failed setup leaves its resources available for inspection and lab-down.sh.
mkdir -p "$work_dir"
cp --reflink=auto "$appliance" "$work_dir/appliance.iso"
cp --reflink=auto "$config_image" "$work_dir/config-image.iso"
cp -a "$script_dir/externalfrr" "$work_dir/externalfrr"
chmod 644 "$work_dir/appliance.iso" "$work_dir/config-image.iso"
if command -v restorecon >/dev/null; then restorecon -R "$work_dir"; fi

# The upstream script changes host sysctls; save their original values for lab-down.sh.
for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv6.seg6_flowlabel \
    net.ipv6.conf.all.seg6_enabled net.ipv6.conf.default.seg6_enabled \
    net.ipv6.conf.lo.seg6_enabled net.ipv4.conf.all.rp_filter \
    net.ipv4.conf.default.rp_filter net.vrf.strict_mode; do
    if value=$(sysctl -n "$key" 2>/dev/null); then
        printf '%s=%s\n' "$key" "$value" >> "$work_dir/sysctls"
    fi
done

envsubst < "$script_dir/xml/underlay-net.xml" > "$work_dir/underlay.xml"
envsubst < "$script_dir/xml/management-net.xml" > "$work_dir/management.xml"
for network in underlay management; do
    "${libvirt[@]}" net-define "$work_dir/$network.xml"
    "${libvirt[@]}" net-start "openpe-$network"
done

# The unmodified upstream script runs FRR, DNS, and NTP on the host network.
ISIS_IFACE=opelabu "$work_dir/externalfrr/run_frr.sh"

# PCI buses 1/2/3 give the guests enp1s0/enp2s0/enp3s0.
# enp2s0 MACs match srv6fullconfig/configimage/agent-config.yaml.
for i in "${!names[@]}"; do
    name=${names[$i]}
    disk="$work_dir/$name.qcow2"
    qemu-img create -f qcow2 "$disk" "${vm_disk_gb}G"
    export VM_NAME="openpe-$name" VM_MEMORY_MIB="$vm_memory_mib" \
        VM_VCPUS="$vm_vcpus" VM_DISK="$disk" WORK_DIR="$work_dir" \
        IDLE_MAC="${idle_macs[$i]}" \
        UNDERLAY_MAC="${underlay_macs[$i]}" \
        MANAGEMENT_MAC="${management_macs[$i]}"
    envsubst < "$script_dir/xml/domain.xml" > "$work_dir/$name.xml"
    "${libvirt[@]}" define "$work_dir/$name.xml"
    "${libvirt[@]}" start "openpe-$name"
done

echo 'OpenPERouter lab started. Use virsh console, podman logs externalfrr, and the generated kubeconfig for manual checks.'
