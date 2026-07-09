#!/bin/bash

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rhcos-iso-path> [output-iso-path]"
    exit 1
fi

ISO_PATH="$1"
OUTPUT_ISO="${2:-$1}"
WORK_DIR=$(mktemp -d)
EXTRACTED_IGN="$WORK_DIR/extracted.ign"
MODIFIED_IGN="$WORK_DIR/modified.ign"
HACK_SCRIPT_FILE="$WORK_DIR/hack-script.sh"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Extracting ignition from ISO: $ISO_PATH"

if sudo coreos-installer iso ignition show "$ISO_PATH" > "$EXTRACTED_IGN" 2>/dev/null && [ -s "$EXTRACTED_IGN" ]; then
    echo "Extracted existing ignition configuration"
else
    echo "No existing ignition found. Aborting"
    exit 1
fi

# Write the hack script to a file to avoid quoting hell
cat > "$HACK_SCRIPT_FILE" << 'HACKSCRIPT_EOF'
#!/bin/bash

LOG_FILE="/tmp/ignition-hack.log"
LOCAL_IGN_DIR="/opt/install-dir"
CONVERTER_IMAGE="quay.io/mavazque/ign-converter:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting ignition hack script"

# Pull the ignition converter image
log "Pulling ignition converter image: $CONVERTER_IMAGE"
if podman pull "$CONVERTER_IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    log "Successfully pulled converter image"
else
    log "ERROR: Failed to pull converter image"
    exit 1
fi

# Wait for a local ignition file (master or worker) to be created.
# The agent installer creates /opt/install-dir/ minutes after boot.
log "Waiting for local ignition file in $LOCAL_IGN_DIR..."
while true; do
    LOCAL_IGN_FILE=$(find "$LOCAL_IGN_DIR" -maxdepth 1 \( -name 'master-*.ign' -o -name 'worker-*.ign' \) -type f 2>/dev/null | head -1)

    if [ -n "$LOCAL_IGN_FILE" ]; then
        log "Found local ignition file: $LOCAL_IGN_FILE"
        break
    fi

    sleep 1
done

# Detect role from filename
case "$LOCAL_IGN_FILE" in
    *worker*) NODE_ROLE="worker" ;;
    *)        NODE_ROLE="master" ;;
esac

# Workers: block reboot until we've baked in the MCS config,
# and use the API VIP (production MCS) instead of rendezvous IP
if [ "$NODE_ROLE" = "worker" ]; then
    log "Worker detected — masking reboot.target to prevent premature reboot"
    systemctl mask reboot.target
    URL="https://192.168.110.10:22623/config/${NODE_ROLE}"
else
    URL="https://192.168.110.2:22623/config/${NODE_ROLE}"
fi

IGN_FILE="/tmp/${NODE_ROLE}-mcs-server.ign"
log "Detected node role: $NODE_ROLE (MCS URL: $URL)"

# Extract ignition version from local file
IGN_VERSION=$(jq -r '.ignition.version' "$LOCAL_IGN_FILE")
if [ -z "$IGN_VERSION" ] || [ "$IGN_VERSION" = "null" ]; then
    log "ERROR: Could not extract ignition version from $LOCAL_IGN_FILE"
    exit 1
fi
log "Ignition version from local file: $IGN_VERSION"

# Extract hostname file config from local ignition
HOSTNAME_CONFIG=$(jq '.storage.files[] | select(.path == "/etc/hostname")' "$LOCAL_IGN_FILE" 2>/dev/null)
if [ -z "$HOSTNAME_CONFIG" ] || [ "$HOSTNAME_CONFIG" = "null" ]; then
    log "WARNING: No /etc/hostname configuration found in local ignition file"
    HOSTNAME_CONFIG=""
else
    log "Found hostname configuration in local ignition file"
fi

# Poll URL until MCS returns a valid ignition response
log "Waiting for valid ignition from $URL..."
while true; do
    if curl -k -s --connect-timeout 1 --max-time 5 -o "$IGN_FILE" "$URL"; then
        if [ -s "$IGN_FILE" ] && jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
            log "Got valid ignition file from MCS ($(wc -c < "$IGN_FILE") bytes)"
            break
        else
            rm -f "$IGN_FILE"
        fi
    fi
    sleep 1
done

# Convert downloaded ignition from v2 to v3
log "Converting downloaded ignition file to spec v3..."
if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "$IGN_FILE" -output "${IGN_FILE%.ign}-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
    mv "${IGN_FILE%.ign}-v3.ign" "$IGN_FILE"
    log "Successfully converted ignition to v3"
else
    log "ERROR: Failed to convert ignition file to v3"
    exit 1
fi

# Merge the hostname config and update version in downloaded ignition
log "Merging hostname config and updating ignition version..."
if [ -n "$HOSTNAME_CONFIG" ]; then
    jq --argjson hostname "$HOSTNAME_CONFIG" --arg version "$IGN_VERSION" '
        .ignition.version = $version |
        .storage.files = (
            [.storage.files[]? | select(.path != "/etc/hostname")] + [$hostname]
        )
    ' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
else
    jq --arg version "$IGN_VERSION" '.ignition.version = $version' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
fi

if [ $? -ne 0 ]; then
    log "ERROR: Failed to merge ignition configurations"
    exit 1
fi
log "Successfully merged ignition configuration"

# Extract arguments from journalctl, retry every 5 seconds until found
log "Extracting coreos-installer arguments from journalctl..."
while true; do
    ARGS=$(journalctl -b | grep 'Writing image and ignition to disk with arguments' | tail -1 | grep -oP 'Writing image and ignition to disk with arguments: \[\K[^\]]+')

    if [ -n "$ARGS" ]; then
        log "Found installer arguments"
        break
    fi

    log "Log line not found, retrying in 5 seconds..."
    sleep 5
done

log "Original arguments: $ARGS"

DISK=$(echo "$ARGS" | grep -oP '/dev/\S+')
log "Target disk: $DISK"

TRANSFORMED_ARGS=$(echo "$ARGS" | sed "s|-i [^ ]*|-i $IGN_FILE|")
TRANSFORMED_ARGS=$(echo "$TRANSFORMED_ARGS" | sed 's/^install //')

# Ensure NM keyfiles (br0, dummy0, etc. from nmstate) are copied to the installed system
if ! echo "$TRANSFORMED_ARGS" | grep -q -- '--copy-network'; then
    TRANSFORMED_ARGS="$TRANSFORMED_ARGS --copy-network"
    log "Added --copy-network to preserve nmstate network config"
fi

COREOS_CMD="coreos-installer install $TRANSFORMED_ARGS"
log "Transformed command: $COREOS_CMD"

log "Backing up /etc/resolv.conf to /tmp/resolv.conf.bk"
cp /etc/resolv.conf /tmp/resolv.conf.bk

log "Writing nameserver to /etc/resolv.conf"
echo 'nameserver 169.254.0.1' > /etc/resolv.conf

# Validate ignition before wiping disk
if ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Ignition file is invalid, aborting before disk wipe"
    cp /tmp/resolv.conf.bk /etc/resolv.conf
    exit 1
fi

log "Wiping filesystem signatures from $DISK"
wipefs -a "$DISK" -f 2>&1 | tee -a "$LOG_FILE"

log "Running: $COREOS_CMD"
$COREOS_CMD 2>&1 | tee -a "$LOG_FILE"
RESULT=${PIPESTATUS[0]}

log "Restoring /etc/resolv.conf from backup"
cp /tmp/resolv.conf.bk /etc/resolv.conf

if [ $RESULT -eq 0 ]; then
    log "coreos-installer completed successfully"

    # Pre-expand XFS to prevent autosave-xfs failure on first boot.
    # On large disks, first-boot xfs_growfs pushes agcount above 128, triggering
    # autosave-xfs in initramfs which then fails. Replicate what the assisted-installer
    # does (OCPBUGS-76382): grow the partition now, run autosave-xfs from the full ISO
    # environment (all RAM available), then grow XFS to fill the partition. The first
    # boot's autosave-xfs will then see agcount < 128 and skip entirely.
    IGNTRANSPOSE="/usr/libexec/ignition-ostree-transposefs"
    if echo "$DISK" | grep -qE '(nvme|mmcblk)'; then
        ROOT_PART="${DISK}p4"
    else
        ROOT_PART="${DISK}4"
    fi

    if [ -b "$ROOT_PART" ] && [ -f "$IGNTRANSPOSE" ]; then
        log "Pre-expanding XFS on $ROOT_PART to normalize agcount before reboot"
        XFS_MNTPT=$(mktemp -d)

        if mount "$ROOT_PART" "$XFS_MNTPT" 2>/dev/null; then
            fsfreeze --unfreeze "$XFS_MNTPT" 2>/dev/null || true
            umount "$XFS_MNTPT"
        fi

        log "Extending partition 4 to fill $DISK"
        growpart "$DISK" 4 2>&1 | tee -a "$LOG_FILE" || true

        log "Running autosave-xfs (threshold=0) to normalize XFS agcount"
        sed 's/threshold=[0-9]*/threshold=0/' "$IGNTRANSPOSE" | bash -s autosave-xfs 2>&1 | tee -a "$LOG_FILE"
        "$IGNTRANSPOSE" restore 2>&1 | tee -a "$LOG_FILE"
        "$IGNTRANSPOSE" cleanup 2>&1 | tee -a "$LOG_FILE"

        log "Growing XFS filesystem to fill partition"
        mount "$ROOT_PART" "$XFS_MNTPT"
        xfs_growfs "$XFS_MNTPT" 2>&1 | tee -a "$LOG_FILE"
        umount "$XFS_MNTPT"
        rmdir "$XFS_MNTPT"

        log "XFS pre-expansion complete"
    else
        log "WARNING: root partition $ROOT_PART or $IGNTRANSPOSE not found, skipping XFS pre-expansion"
    fi

    if [ "$NODE_ROLE" = "worker" ]; then
        log "Worker: unmask reboot.target and rebooting"
        systemctl unmask reboot.target
        systemctl reboot
    fi
else
    log "ERROR: coreos-installer failed with exit code $RESULT"
    if [ "$NODE_ROLE" = "worker" ]; then
        systemctl unmask reboot.target
    fi
    exit $RESULT
fi

log "Ignition hack script completed"
HACKSCRIPT_EOF

# Base64 encode the script (use printf to avoid trailing newline)
SCRIPT_B64=$(base64 -w0 < "$HACK_SCRIPT_FILE")

# Systemd unit file
SYSTEMD_UNIT='[Unit]
Description=Ignition Hack Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ignition-hack.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'

# Merge into existing ignition
echo "Merging script and systemd unit into ignition..."
jq --arg script_b64 "$SCRIPT_B64" --arg unit "$SYSTEMD_UNIT" '
    .storage = (.storage // {}) |
    .storage.files = ((.storage.files // []) + [{
        "group": {},
        "overwrite": true,
        "path": "/usr/local/bin/ignition-hack.sh",
        "user": {
          "name": "root"
        },
        "mode": 365,
        "contents": {
            "source": ("data:text/plain;charset=utf-8;base64," + $script_b64),
            "verification": {}
        }
    }]) |
    .systemd = (.systemd // {}) |
    .systemd.units = ((.systemd.units // []) + [{
        "name": "ignition-hack.service",
        "enabled": true,
        "contents": $unit
    }])
' "$EXTRACTED_IGN" > "$MODIFIED_IGN"

echo "--- Generated merged ignition ---"

if [ "$OUTPUT_ISO" != "$ISO_PATH" ]; then
    echo "Copying ISO to: $OUTPUT_ISO"
    cp "$ISO_PATH" "$OUTPUT_ISO"
fi

echo "Removing any existing embedded ignition..."
sudo coreos-installer iso ignition remove "$OUTPUT_ISO" 2>/dev/null || true

echo "Embedding modified ignition into ISO..."
sudo coreos-installer iso ignition embed -i "$MODIFIED_IGN" "$OUTPUT_ISO"

echo "Done! Modified ISO: $OUTPUT_ISO"
