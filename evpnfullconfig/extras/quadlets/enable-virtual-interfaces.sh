#!/bin/bash
# Inject ENABLE_VIRTUAL_INTERFACES=true into assisted-service.env
# so that the assisted-service inventory includes virtual interfaces (bridges, etc.).
# Runs before assisted-service-pod.service.
#
# The env file is initially created by the appliance ignition, then
# overwritten by load-config-iso.sh when the config-image ISO is mounted.
# We wait for load-config-iso to finish (indicated by SERVICE_IMAGE being
# set in the file) before injecting, to avoid being overwritten.

ENV_FILE="/usr/local/share/assisted-service/assisted-service.env"

echo "Waiting for load-config-iso to finish..."
for i in $(seq 1 60); do
    # Find the active load-config-iso instance and check if it completed
    unit=$(systemctl list-units 'load-config-iso@*' --no-legend --no-pager 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$unit" ] && systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "load-config-iso ($unit) has completed."
        break
    fi
    sleep 5
done

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE does not exist after waiting. Failing."
    exit 1
fi

if grep -q "^ENABLE_VIRTUAL_INTERFACES=" "$ENV_FILE"; then
    echo "ENABLE_VIRTUAL_INTERFACES already set. Exiting cleanly."
    exit 0
fi

echo "Injecting ENABLE_VIRTUAL_INTERFACES=true..."
if echo "ENABLE_VIRTUAL_INTERFACES=true" >> "$ENV_FILE"; then
    echo "SUCCESS: ENABLE_VIRTUAL_INTERFACES injection complete."
else
    echo "ERROR: Failed to write to $ENV_FILE."
    exit 1
fi

if grep -q "^DISABLED_HOST_VALIDATIONS=" "$ENV_FILE"; then
    echo "DISABLED_HOST_VALIDATIONS already set. Skipping."
else
    echo "Injecting DISABLED_HOST_VALIDATIONS=belongs-to-majority-group..."
    if echo "DISABLED_HOST_VALIDATIONS=belongs-to-majority-group" >> "$ENV_FILE"; then
        echo "SUCCESS: DISABLED_HOST_VALIDATIONS injection complete."
    else
        echo "ERROR: Failed to write DISABLED_HOST_VALIDATIONS to $ENV_FILE."
        exit 1
    fi
fi

exit 0
else
    echo "ERROR: Failed to write to $ENV_FILE."
    exit 1
fi
