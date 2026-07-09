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
URL="https://192.168.110.2:22623/config/master"
IGN_FILE="/tmp/master-mcs-server.ign"
LOCAL_IGN_DIR="/opt/install-dir"
CONVERTER_IMAGE="quay.io/mavazque/ign-converter:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting ignition hack script"

# Mask reboot.target immediately so neither the agent nor the OS can reboot
# the node before we have finished writing config.ign to the boot partition.
# We unmask and reboot explicitly at the end.
log "Masking reboot.target to hold the node until ignition is written"
systemctl mask reboot.target

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

# Both workers and masters fetch ignition from the bootstrap MCS on the rendezvous
# node (192.168.110.2:22623). This MCS is available throughout the entire bootstrap
# phase and serves the full ignition (including MCO-compiled MachineConfigs such as
# FRR/quadlet configs). The cluster MCS at the API VIP (192.168.110.10:22623) is
# firewalled from the provisioning network during installation.
URL="https://192.168.110.2:22623/config/${NODE_ROLE}"

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

# Inject registry.redhat.io mirror into the registries.conf so that
# toolbox / podman run can resolve images from the appliance registry
# after reboot (the cluster IDMS/ITMS only cover OCP release images).
MIRROR_CONF='
[[registry]]
  prefix = ""
  location = "registry.redhat.io"
  mirror-by-digest-only = false

  [[registry.mirror]]
    location = "registry.appliance.openshift.com:22625"
    insecure = true
'
MIRROR_CONF_B64=$(echo "$MIRROR_CONF" | base64 -w0)
MIRROR_PATH="/etc/containers/registries.conf.d/appliance-redhat-mirror.conf"
log "Injecting $MIRROR_PATH into ignition..."
jq --arg data "$MIRROR_CONF_B64" --arg path "$MIRROR_PATH" '
    .storage.files = (
        [.storage.files[]? | select(.path != $path)] + [{
            "path": $path,
            "mode": 420,
            "overwrite": true,
            "contents": {
                "source": ("data:text/plain;charset=utf-8;base64," + $data),
                "verification": {}
            }
        }]
    )
' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
log "Injected registry mirror configuration"

# The default policy.json requires GPG signatures for registry.redhat.io
# images, but the appliance mirror copy is unsigned.  Override the policy
# to accept unsigned images from the appliance registry.
POLICY_OVERRIDE='{
    "default": [{"type": "insecureAcceptAnything"}],
    "transports": {
        "docker": {
            "registry.appliance.openshift.com:22625": [{"type": "insecureAcceptAnything"}],
            "registry.redhat.io": [{"type": "insecureAcceptAnything"}]
        },
        "docker-daemon": {
            "": [{"type": "insecureAcceptAnything"}]
        }
    }
}'
POLICY_B64=$(echo "$POLICY_OVERRIDE" | base64 -w0)
POLICY_PATH="/etc/containers/policy.json"
log "Injecting relaxed $POLICY_PATH into ignition..."
jq --arg data "$POLICY_B64" --arg path "$POLICY_PATH" '
    .storage.files = (
        [.storage.files[]? | select(.path != $path)] + [{
            "path": $path,
            "mode": 420,
            "overwrite": true,
            "contents": {
                "source": ("data:text/plain;charset=utf-8;base64," + $data),
                "verification": {}
            }
        }]
    )
' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
log "Injected container signature policy override"

# Wait for the assisted-installer container to exit before touching the disk.
# On non-bootstrap masters it exits right after the registry copy; on the
# bootstrap/rendezvous master it exits only after the full bootstrap phase
# completes (etcd quorum, API VIP handoff). This is the cleanest signal that
# the installer is done with all disk operations on this node.
log "Waiting for assisted-installer and next-step-runner containers to exit..."
while sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(assisted-installer|next-step-runner)$'; do
    log "installer containers still running, retrying in 5 seconds..."
    sleep 5
done
log "installer containers exited, proceeding to swap ignition"

# Validate ignition before writing
if ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Ignition file is invalid, aborting"
    systemctl unmask reboot.target
    exit 1
fi

# Write the MCS ignition directly to the boot partition (/dev/disk/by-label/boot).
# The agent already set up the disk correctly: RHCOS image, iri-registry, and XFS
# agcount fixed via autosave-xfs (PR #2034). We only replace the ignition so the
# second boot gets the quadlet/FRR configs needed to establish the SRv6 overlay.
log "Writing MCS ignition to boot partition..."
BOOT_MNT=$(mktemp -d)
if mount /dev/disk/by-label/boot "$BOOT_MNT" 2>/dev/null; then
    fsfreeze --unfreeze "$BOOT_MNT" 2>/dev/null || true
    cp "$IGN_FILE" "$BOOT_MNT/ignition/config.ign"
    sync
    fsfreeze --freeze "$BOOT_MNT" 2>/dev/null || true
    umount "$BOOT_MNT"
    rmdir "$BOOT_MNT"
    log "Successfully wrote ignition to boot partition"
else
    rmdir "$BOOT_MNT"
    log "ERROR: Could not mount boot partition /dev/disk/by-label/boot"
    systemctl unmask reboot.target
    exit 1
fi

log "Ignition hack script completed — unmasking reboot.target and rebooting"
systemctl unmask reboot.target
systemctl reboot
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
