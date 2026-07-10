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

MASTER_IGN_FILE="/tmp/master-mcs-server.ign"

# Wait for the local ignition file — needed for role detection and hostname.
log "Waiting for local ignition file in $LOCAL_IGN_DIR..."
LOCAL_IGN_FILE=""
while true; do
    LOCAL_IGN_FILE=$(find "$LOCAL_IGN_DIR" -maxdepth 1 \( -name 'master-*.ign' -o -name 'worker-*.ign' \) -type f 2>/dev/null | head -1)
    [ -n "$LOCAL_IGN_FILE" ] && break
    sleep 5
done
log "Found local ignition file: $LOCAL_IGN_FILE"

# Detect role from filename
case "$LOCAL_IGN_FILE" in
    *worker*) NODE_ROLE="worker" ;;
    *)        NODE_ROLE="master" ;;
esac

IGN_FILE="/tmp/final-${NODE_ROLE}.ign"
log "Detected node role: $NODE_ROLE"

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

if [ "$NODE_ROLE" = "master" ]; then
    # Masters: fetch from bootstrap MCS (available throughout bootstrap).
    log "Fetching master ignition from bootstrap MCS..."
    while true; do
        if curl -k -s --connect-timeout 5 --max-time 30 -o "$MASTER_IGN_FILE" "https://192.168.110.2:22623/config/master" 2>/dev/null && \
           [ -s "$MASTER_IGN_FILE" ] && jq -e '.ignition.version' "$MASTER_IGN_FILE" >/dev/null 2>&1; then
            log "Got master ignition from bootstrap MCS ($(wc -c < "$MASTER_IGN_FILE") bytes)"
            break
        fi
        rm -f "$MASTER_IGN_FILE"
        log "Bootstrap MCS not ready, retrying in 5 s..."
        sleep 5
    done

    log "Converting master ignition to spec v3..."
    if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "$MASTER_IGN_FILE" -output "${MASTER_IGN_FILE%.ign}-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
        mv "${MASTER_IGN_FILE%.ign}-v3.ign" "$MASTER_IGN_FILE"
        log "Successfully converted master ignition to v3"
    else
        log "ERROR: Failed to convert master ignition to v3"
        exit 1
    fi

    log "Building master ignition..."
    if [ -n "$HOSTNAME_CONFIG" ]; then
        jq --argjson hostname "$HOSTNAME_CONFIG" --arg version "$IGN_VERSION" '
            .ignition.version = $version |
            .storage.files = (
                [.storage.files[]? | select(.path != "/etc/hostname")] + [$hostname]
            )
        ' "$MASTER_IGN_FILE" > "$IGN_FILE"
    else
        jq --arg version "$IGN_VERSION" '.ignition.version = $version' \
            "$MASTER_IGN_FILE" > "$IGN_FILE"
    fi
else
    # Workers: fetch full ignition from the production MCS at the API VIP.
    # By the time workers see "Rebooting node", the cluster is up and the
    # production MCS is serving /config/worker.
    WORKER_IGN_FILE="/tmp/worker-mcs.ign"
    log "Fetching worker ignition from production MCS..."
    while true; do
        if curl -k -s --connect-timeout 5 --max-time 30 -o "$WORKER_IGN_FILE" "https://192.168.110.10:22623/config/worker" 2>/dev/null && \
           [ -s "$WORKER_IGN_FILE" ] && jq -e '.ignition.version' "$WORKER_IGN_FILE" >/dev/null 2>&1; then
            log "Got worker ignition from production MCS ($(wc -c < "$WORKER_IGN_FILE") bytes)"
            break
        fi
        rm -f "$WORKER_IGN_FILE"
        log "Production MCS not ready, retrying in 10 s..."
        sleep 10
    done

    log "Converting worker ignition to spec v3..."
    if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "$WORKER_IGN_FILE" -output "${WORKER_IGN_FILE%.ign}-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
        mv "${WORKER_IGN_FILE%.ign}-v3.ign" "$WORKER_IGN_FILE"
        log "Successfully converted worker ignition to v3"
    else
        log "ERROR: Failed to convert worker ignition to v3"
        exit 1
    fi

    cp "$WORKER_IGN_FILE" "$IGN_FILE"
fi

if [ $? -ne 0 ] || ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Failed to build ignition"
    exit 1
fi
log "Successfully built ignition ($(wc -c < "$IGN_FILE") bytes)"

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

# Detect whether this is the bootstrap/rendezvous node by checking if the
# assisted-service container is running locally.  The bootstrap node must stay
# up until waitForBootstrapComplete; the other nodes only need to wait until
# their own disk operations are done.
if sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^service$'; then
    log "Bootstrap node detected — waiting for assisted-installer to exit (implies bootstrap complete)"
    while sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^assisted-installer$'; do
        log "assisted-installer still running, retrying in 5 seconds..."
        sleep 5
    done
    log "assisted-installer exited, proceeding to write ignition"
else
    # Non-bootstrap node: wait for "Rebooting node" in the journal.
    # The local assisted-installer logs this just before calling shutdown -r,
    # after all disk operations (image write + ostree deployment) are complete.
    # Exclude ignition-hack lines to prevent matching our own log messages.
    log "Waiting for installer reboot signal..."
    while ! journalctl -b --no-pager -q 2>/dev/null | grep -v 'ignition-hack' | grep -q 'Rebooting node'; do
        sleep 5
    done
    log "Rebooting node seen, proceeding to fetch MCS ignition and write"
fi

# Validate ignition before writing
if ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Ignition file is invalid, aborting"
    systemctl unmask reboot.target
    exit 1
fi

# Write the MCS ignition to the boot partition.
# The installer mounts sda3 (labeled "boot") via nsenter --mount into the host
# namespace at /var/mnt, then freezes it with FIFREEZE before unmounting its own
# /mnt/boot handle.  Because /var/mnt still holds a reference to the superblock,
# the freeze persists.  Find the existing mount with findmnt instead of trying to
# create a new one (which would fail with EBUSY or succeed on a stale tmpdir).
log "Writing MCS ignition to boot partition..."
BOOT_MNT=$(findmnt -n -o TARGET /dev/disk/by-label/boot 2>/dev/null | head -1)
_OWN_BOOT_MOUNT=0
if [ -z "$BOOT_MNT" ]; then
    BOOT_MNT=$(mktemp -d)
    if mount /dev/disk/by-label/boot "$BOOT_MNT" 2>/dev/null; then
        _OWN_BOOT_MOUNT=1
    else
        rmdir "$BOOT_MNT"
        log "ERROR: Boot partition not found or mountable"
        systemctl unmask reboot.target
        exit 1
    fi
else
    log "Boot partition already mounted at $BOOT_MNT"
fi
fsfreeze --unfreeze "$BOOT_MNT" 2>/dev/null || true
cp "$IGN_FILE" "$BOOT_MNT/ignition/config.ign"
sync
if [ "$_OWN_BOOT_MOUNT" -eq 1 ]; then
    umount "$BOOT_MNT"
    rmdir "$BOOT_MNT"
fi
log "Successfully wrote ignition to boot partition"

# Wait for "Rebooting node" before triggering the actual reboot.
# The local assisted-installer logs this just before calling shutdown -r,
# meaning it has already sent the "Rebooting" stage update to the
# assisted-service.  Rebooting before this point causes the service to
# mark the node as disconnected/error.
log "Rebooting node seen — unmasking reboot.target and rebooting"
systemctl unmask reboot.target
systemctl reboot
systemctl unmask reboot.target
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
