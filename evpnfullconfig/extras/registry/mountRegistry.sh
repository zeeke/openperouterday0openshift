#!/bin/bash

BIGGEST_ROM=$(lsblk -dnbo NAME,SIZE,TYPE | awk '$3=="rom" {print $1, $2}' | sort -k2 -n | tail -n1 | awk '{print $1}')

if [ -z "$BIGGEST_ROM" ]; then
    echo "Error: No DVD/ROM devices found."
    exit 1
fi

DEVICE_PATH="/dev/$BIGGEST_ROM"
MOUNT_POINT="/media/iso"

echo "Largest device found: $DEVICE_PATH"

if [ ! -d "$MOUNT_POINT" ]; then
    sudo mkdir -p "$MOUNT_POINT"
fi

echo "Setting up systemd-automount for $DEVICE_PATH at $MOUNT_POINT..."
sudo systemd-mount --automount=yes --collect "$DEVICE_PATH" "$MOUNT_POINT"

echo "Done. Access $MOUNT_POINT to trigger the mount."
