#!/bin/bash
# patch_appliance.sh - Patch an existing appliance ISO by embedding
# OpenPERouter rawconfig quadlets, configs, registry mirrors, DNS overrides,
# and the ignition hack agent into it.
#
# This is the rawconfig variant: it compiles openperouter-raw.bu (the single
# source of truth for file lists and systemd units) and merges the resulting
# ignition with appliance-specific extras (registry mirrors, DNS, SSH key).
#
# Usage: patch_appliance.sh <appliance_iso> <ocp_dir>
#
#   appliance_iso         Path to the appliance ISO to patch
#   ocp_dir               OCP working directory containing cache/*/cluster-resources
#
# Requires: coreos-installer, jq, yq (mikefarah v4), butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"
RAWCONFIG_BU="${SCRIPTDIR}/../configimage/openperouter-raw.bu"

appliance_iso="$1"
ocp_dir="$2"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found: ${appliance_iso}"
    exit 1
fi

if [[ ! -f "${RAWCONFIG_BU}" ]]; then
    echo "ERROR: openperouter-raw.bu not found: ${RAWCONFIG_BU}"
    exit 1
fi

# ============================================================
# Step 1: Compile openperouter-raw.bu → ignition
# ============================================================
echo "==> Compiling openperouter-raw.bu..."

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# butane --raw on an openshift-variant .bu outputs ignition JSON directly
# (without --raw it would produce a MachineConfig YAML wrapper)
butane --raw --files-dir="${EXTRASDIR}" "${RAWCONFIG_BU}" \
    > "${tmpdir}/openperouter.ign"


# ============================================================
# Step 2: Build extras ignition (registry mirrors, SSH key)
# ============================================================
echo "==> Building appliance extras..."

staging="${tmpdir}/staging"
mkdir -p "${staging}"

bu="${tmpdir}/extras.bu"
bu_files=""
bu_units=""

# --- Generate registries.conf drop-in ---
registries_conf="${staging}/appliance-mirrors.conf"
cluster_resources="${ocp_dir}/cache/"*"/cluster-resources"
{
    for yaml_file in ${cluster_resources}/idms-oc-mirror.yaml ${cluster_resources}/itms-oc-mirror.yaml; do
        if [[ ! -f "${yaml_file}" ]]; then
            continue
        fi
        if [[ "${yaml_file}" == *idms* ]]; then
            digest_only="true"
        else
            digest_only="false"
        fi
        yq -r '.spec.imageDigestMirrors // .spec.imageTagMirrors // [] | .[] | .source as $src | .mirrors[] | [$src, .] | @tsv' "${yaml_file}" | \
        while IFS=$'\t' read -r source mirror; do
            if [[ -z "${source}" || -z "${mirror}" || "${source}" == "---" ]]; then
                continue
            fi
            cat <<TOML

[[registry]]
  prefix = ""
  location = "${source}"
  mirror-by-digest-only = ${digest_only}

  [[registry.mirror]]
    location = "${mirror}"
    insecure = true
TOML
        done
    done
} > "${registries_conf}"

# The appliance embeds additionalImages into its local registry but the
# auto-generated IDMS/ITMS only cover OCP release images.  Add a mirror
# rule so that registry.redhat.io pulls (e.g. toolbox, support-tools)
# are served from the appliance registry.
cat >> "${registries_conf}" <<TOML

[[registry]]
  prefix = ""
  location = "registry.redhat.io"
  mirror-by-digest-only = false

  [[registry.mirror]]
    location = "registry.appliance.openshift.com:22625"
    insecure = true
TOML

if [[ -s "${registries_conf}" ]]; then
    bu_files+="    - path: /etc/containers/registries.conf.d/appliance-mirrors.conf
      mode: 0644
      overwrite: true
      contents:
        local: appliance-mirrors.conf
"
fi

# --- Override container signature policy ---
# The default policy.json requires GPG signatures for registry.redhat.io
# images, but the appliance mirror copy is unsigned.
policy_json="${staging}/appliance-policy.json"
cat > "${policy_json}" <<'POLICY'
{
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
}
POLICY
bu_files+="    - path: /etc/containers/policy.json
      mode: 0644
      overwrite: true
      contents:
        local: appliance-policy.json
"

# --- DNS hosts entries for disconnected install ---
# During install, the overlay network doesn't exist yet so the DNS
# server is unreachable. The API hostnames must resolve to the
# rendezvous IP for bootkube and the MCS to work.
rendezvous_ip="192.168.110.2"
cluster_name="sno-lab"
base_domain="example.com"

hosts_content="${rendezvous_ip} api.${cluster_name}.${base_domain} api-int.${cluster_name}.${base_domain}"
hosts_b64=$(echo "${hosts_content}" | base64 -w0)

bu_files+="    - path: /etc/hosts.d/sno-lab-api.conf
      mode: 0644
      overwrite: true
      contents:
        source: data:text/plain;base64,${hosts_b64}
"
bu_units+="    - name: update-etc-hosts.service
      enabled: true
      contents: |
        [Unit]
        Description=Add API hostnames to /etc/hosts for disconnected install
        DefaultDependencies=no
        Before=bootkube.service kubelet.service
        After=local-fs.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/bash -c 'grep -qF api.${cluster_name}.${base_domain} /etc/hosts || cat /etc/hosts.d/sno-lab-api.conf >> /etc/hosts'

        [Install]
        WantedBy=multi-user.target
"

# --- Compile extras butane → ignition ---
extras_ign="${tmpdir}/extras.ign"
if [[ -n "${bu_files}" || -n "${bu_units}" ]]; then
    {
        echo "variant: fcos"
        echo "version: 1.5.0"
        if [[ -n "${SSH_PUB_KEY:-}" ]]; then
            echo "passwd:"
            echo "  users:"
            echo "    - name: core"
            echo "      ssh_authorized_keys:"
            echo "        - \"${SSH_PUB_KEY}\""
        fi
        if [[ -n "${bu_files}" ]]; then
            echo "storage:"
            echo "  files:"
            printf '%s' "${bu_files}"
        fi
        if [[ -n "${bu_units}" ]]; then
            echo "systemd:"
            echo "  units:"
            printf '%s' "${bu_units}"
        fi
    } > "${bu}"

    butane --raw --strict -d "${staging}" "${bu}" > "${extras_ign}"
else
    echo '{"ignition":{"version":"3.4.0"}}' > "${extras_ign}"
fi

# ============================================================
# Step 3: Merge everything into the ISO
# ============================================================
echo "==> Merging ignition into appliance ISO..."

# Extract existing ISO ignition
sudo coreos-installer iso ignition show "${appliance_iso}" > "${tmpdir}/original.ign" 2>/dev/null \
    || echo '{"ignition":{"version":"3.4.0"}}' > "${tmpdir}/original.ign"

# Merge: original + openperouter + extras (dedup by path/name, last wins)
jq -s '
    def dedup_files: group_by(.path) | map(last);
    def dedup_units: group_by(.name) | map(last);
    reduce .[] as $ign ({ignition:{version:"3.4.0"}, storage:{files:[]}, systemd:{units:[]}, passwd:{users:[]}};
        .ignition.version = ([.ignition.version, $ign.ignition.version] |
            map(split(".") | map(tonumber)) | sort | last | map(tostring) | join(".")) |
        .storage.files = (.storage.files + ($ign.storage.files // [])) |
        .systemd.units = (.systemd.units + ($ign.systemd.units // [])) |
        .passwd.users = (.passwd.users + ($ign.passwd.users // []))
    ) |
    .storage.files |= dedup_files |
    .systemd.units |= dedup_units |
    .passwd.users |= (group_by(.name) | map(last)) |
    if (.passwd.users | length) == 0 then del(.passwd) else . end
' "${tmpdir}/original.ign" "${tmpdir}/openperouter.ign" "${extras_ign}" \
    > "${tmpdir}/merged.ign"

# Embed merged ignition into ISO
sudo coreos-installer iso ignition embed -f -i "${tmpdir}/merged.ign" "${appliance_iso}"

echo "==> Embedded OpenPERouter ignition into appliance ISO"

# ============================================================
# Step 4: Add kernel args for serial console, hugepages, IOMMU
# ============================================================
sudo coreos-installer iso kargs modify \
    -a console=tty0 -a console=ttyS0,115200n8 \
    -a default_hugepagesz=1G -a hugepagesz=1G -a hugepages=8 \
    -a iommu=pt -a intel_iommu=on \
    "${appliance_iso}"

echo "==> Done! Appliance ISO patched: ${appliance_iso}"
