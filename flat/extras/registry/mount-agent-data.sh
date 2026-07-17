#!/usr/bin/env bash
set -euo pipefail

ISO_DIR=/run/media/iso
REGISTRY_DATA_DIR=/var/lib/iri-registry

# The name must NOT start with "agent"
DEV_NAME=ocp-registry-data
MNT_DIR=/mnt/agentdata
DATA_FILES=$ISO_DIR/registry/data*

verify_registry_data_readable() {
    if mountpoint -q "$MNT_DIR" 2>/dev/null || [[ -L "$MNT_DIR" ]]; then
        :
    else
        echo "ERROR: $MNT_DIR is not a mount point or symlink to registry data after agent data setup." >&2
        exit 1
    fi
}

create_data_device() {
    local loop_sizes=()
    local f device
    for f in $DATA_FILES
    do
        device=$(losetup --find --show --read-only "$f")
        loop_sizes+=("$device")
    done

    local start=0
    local size
    (
        for device in "${loop_sizes[@]}"; do
            size=$(blockdev --getsz "$device")
            echo "$start $size linear $device 0"
            start=$((start + size))
        done
    ) | dmsetup create "${DEV_NAME}"
}

wait_for_iso_mount() {
    while ! mountpoint -q $ISO_DIR; do
        echo "Waiting for $ISO_DIR to be fully mounted..."
        sleep 5
    done
}

mount_registry_data_iso() {
    # Mount the registry data directory if exists (>=4.21)
    if [ -d "$REGISTRY_DATA_DIR" ]; then
        if [ ! -L "$MNT_DIR" ]; then
            rm -rf $MNT_DIR
            ln -s $REGISTRY_DATA_DIR $MNT_DIR
        fi
        return
    fi

    registry_data_iso=/home/core/registry_data.iso
    if [ ! -f "$registry_data_iso" ]; then
        wait_for_iso_mount
        cat $DATA_FILES > "$registry_data_iso"
    fi

    mount -o ro "$registry_data_iso" "$MNT_DIR"
}

mkdir -p $MNT_DIR

if [ "true" = "true" ]; then
    if [ "true" = "true" ]; then
        wait_for_iso_mount

        if ! dmsetup info "${DEV_NAME}" > /dev/null 2>&1; then
            create_data_device
        fi

        if ! mountpoint -q "$MNT_DIR"; then
            mount -o ro "/dev/mapper/${DEV_NAME}" "$MNT_DIR"
        fi
    else
        mount_registry_data_iso
    fi
else # Disk image mode
    mount -o ro /dev/disk/by-partlabel/agentdata "$MNT_DIR"
fi

verify_registry_data_readable
