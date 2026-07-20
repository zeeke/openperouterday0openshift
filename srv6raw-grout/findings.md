# Codebase Validation Findings

Review of srv6raw-grout against architecture.md and internal consistency.
Audited all files across build scripts, runtime scripts, butane/quadlets, and manifests.

---

## HIGH Severity (fixed)

### 1. `openperouter-node-index.sh:7` -- Extra `}` makes HOST_VF contain a literal brace

```bash
HOST_VF="${1:-eno12399v2}}"
```

The trailing `}` is outside the parameter expansion. `HOST_VF` evaluates to `eno12399v2}` (with a trailing brace). Every `ip addr show dev "$HOST_VF"` lookup fails because interface `eno12399v2}` does not exist. The script wastes all 60 retries on the wrong name before falling through to `br-ex`. If `br-ex` isn't up yet either, the script fails entirely and `node-config.yaml` is never written -- blocking the controller.

**Fix:** `HOST_VF="${1:-eno12399v2}"`

---

### 2. `controller.container:14,24` + `controllerpod.pod` -- `Network=host` silently ignored inside pod (fixed)

`controller.container` specifies `Network=host` (line 24) and `Pod=controllerpod.pod` (line 14). In Podman, when a container is part of a pod, the pod's infra container owns the network namespace -- per-container `--network` flags are ignored. `controllerpod.pod` has no `Network=` directive, so it defaults to bridge networking. The controller runs without host network access despite the explicit comment stating it needs it.

**Fix:** Add `Network=host` to `controllerpod.pod` under `[Pod]`, or run controller as a standalone container without `Pod=`.

---

### 3. FRR templates + `setup-underlay.sh:230,250` -- Empty `BR0_SUBNET_V6` produces invalid FRR config

If no IPv6 address is found, `BR0_SUBNET_V6=""` (line 230). In `openpe_evpn.yaml.template:86`, this renders as:

```
 address-family ipv6 unicast
  network 
```

Invalid FRR syntax. FRR rejects the entire config block, which can break BGP for all address families in that VRF, not just IPv6.

**Fix:** Guard the `network` line in the template with a conditional, or set a sane default.

---

### 4. `setup-underlay.sh:128` -- SRv6 uSID node-ID of 0 when LAST_OCTET=0

```bash
SRV6_NODE_ID="${LAST_OCTET}"
```

If a host IP ends in `.0` (valid in /23 or larger subnets), `SRV6_NODE_ID` becomes `0`. The `0000` node field is the uSID End-of-Container marker -- this corrupts SRv6 packet processing for the entire domain.

**Fix:** Validate `LAST_OCTET != 0` or offset by 1.

---

### 5. `setup-underlay.sh:268` -- Stale FRR PID baked into vars file

```bash
FRR_PID="$FRR_PID"
```

The PID is captured once at runtime and persisted. If FRR restarts (crash, OOM, podman restart), any downstream script sourcing this file operates on a dead or wrong process. Additionally, no downstream script actually consumes `FRR_PID` from this file.

**Fix:** Remove `FRR_PID` from the vars file; look it up dynamically via `frr_netns_pid` when needed.

---

### 6. `hackagent.sh` (embedded script) -- No error handling; silent failures in critical operations

The embedded `ignition-hack.sh` (~330 lines) runs without `set -e` or `set -o pipefail`:

- `sgdisk` partition operations pipe through `tee`, masking exit codes. A failed `sgdisk -d` lets `sgdisk -n` proceed on the same partition, potentially corrupting the GPT.
- `dd` writing ignition to the boot partition suppresses stderr (`2>/dev/null`) with no exit-code check. If it fails, the script reboots the node with missing/stale ignition -- unrecoverable.
- Multiple `jq` transforms have no error handling.

**Fix:** Add `set -eo pipefail` to the embedded script. Check exit codes after `dd` and `sgdisk`.

---

## MEDIUM Severity

### 7. `openperouter-raw.bu:267` / `openperouter-raw-worker.bu:247` -- `Before=` references non-existent systemd unit names

```
Before=controllerpod.service routerpod.service
```

Quadlet pod files generate service names with a `-pod` suffix: `controllerpod-pod.service` and `routerpod-pod.service`. systemd silently ignores `Before=` constraints on non-existent units, so `openperouter-node-index.service` has no ordering guarantee relative to the pods. Race condition on `node-config.yaml`.

**Fix:** `Before=controllerpod-pod.service routerpod-pod.service`

---

### 8. `openperouter-raw.bu:158-163` -- Butane enables non-existent service names

```yaml
- name: controllerpod.service
  enabled: true
- name: routerpod.service
  enabled: true
```

Creates dangling symlinks. Functionally harmless (container units pull in pods transitively), but produces `systemctl` warnings.

**Fix:** Use `controllerpod-pod.service` and `routerpod-pod.service`.

---

### 9. `frr.container:26-27` + `reloader.container:9` -- SELinux `:Z` conflict on overlapping volume paths

FRR mounts individual files from `/etc/perouter/frr/` with `:Z` (private label); reloader mounts the entire `/etc/perouter/frr` directory with `:Z`. Both are in the same `routerpod` pod. The last container to process its volumes wins; the other gets SELinux denials.

**Fix:** Change `:Z` to `:z` (lowercase -- shared label) on volumes shared between containers in the same pod.

---

### 10. `openperouter-raw.bu:190-192` -- `setup-underlay.service` has `After=grout.service frr.service` but no `Requires=`/`Wants=`

`After=` only affects ordering *if both units are starting*. If grout or frr fail to start, setup-underlay starts without them and crashes on `grcli` calls.

**Fix:** Add `Wants=grout.service frr.service`.

---

### 11. `setup-underlay.sh:57` -- `UNDERLAY_NIC` used before guaranteed set

If the env file (`vpn-setup.env`) is missing, `UNDERLAY_NIC` has no default. `set -u` triggers "unbound variable" on the log line at line 57, before any useful logic runs.

**Fix:** Add a default: `UNDERLAY_NIC="${UNDERLAY_NIC:-eno12399np0}"`.

---

### 12. `setup-underlay.sh:229` -- Hardcoded /24 assumption for BR0_SUBNET

```bash
BR0_SUBNET="${HOST_IP%.*}.0/24"
```

Blindly assumes the host network is a /24. Wrong for /23, /25, or other prefix lengths -- causes incorrect BGP route advertisement.

**Fix:** Parse the actual prefix length from `ip addr` output.

---

### 13. `setup-underlay.sh:231-233` -- Fragile IPv6 subnet derivation via sed

```bash
BR0_SUBNET_V6="$(echo "$BR0_IP_V6" | sed 's/:[^:]*$//' | sed 's/:*$//')::/64"
```

Breaks for addresses where `::` appears before the last group (e.g. `fd00:110::1:2` produces `fd00:110::1::/64` -- invalid double `::`). Also wrong for fully-expanded addresses where the /64 boundary is at the 4th group.

**Fix:** Use `ip -j addr show` with jq to extract the prefix, or parse the prefix length.

---

### 14. `setup-network.sh:40` -- Unbound variable crash if vars file missing

With `set -u` active, expanding `$ROUTER_ID` (never set if vars file is absent) crashes with a cryptic bash error before the friendly error message at lines 45-48 is reached.

**Fix:** Guard the variable access or check vars file existence before sourcing.

---

### 15. `setup-network.sh:61-64` -- No rollback on partial grcli failure

VRF, bridge, VXLAN, and VLAN are created sequentially. A failure partway through leaves orphaned objects in grout. Re-runs fail ("already exists") without manual cleanup.

**Fix:** Add a `trap` to clean up partial state, or make commands idempotent.

---

### 16. `mount-agent-data.sh:69-70` -- Hardcoded `"true" = "true"` -- dead code branches

```bash
if [ "true" = "true" ]; then
    if [ "true" = "true" ]; then
```

Likely template placeholders that were never substituted. The "disk image mode" and alternative mount paths are unreachable.

**Fix:** Remove dead branches or restore the template variables.

---

### 17. `mount-agent-data.sh:42-45` -- Infinite wait loop with no timeout

```bash
while ! mountpoint -q $ISO_DIR; do
    sleep 5
done
```

If the ISO is never mounted, this blocks the entire bootstrap forever.

**Fix:** Add a retry limit with a diagnostic message.

---

### 18. `load-registry-image.sh` -- Missing `set -euo pipefail`

If `podman pull` fails, `IMAGE_ID_FROM_PULL` is empty and the script exits 0. The registry container later fails with a confusing "image not found" error.

---

### 19. `apply-manifests.sh:20-22` -- API server wait loop has no timeout

```bash
until oc get ns >/dev/null 2>&1; do sleep 5; done
```

Loops forever if the API server never comes up.

---

### 20. `apply-manifests.sh:14` -- No existence check for `grout.env`

`source /etc/openperouter/grout.env` crashes if the file is missing. Variables `GROUT_CPUS` and `GROUT_HUGEPAGES_1G` would then be undefined.

---

### 21. `patch_appliance.sh:186-191` -- `SSH_PUB_KEY` env var never set by caller

`generate_appliance.sh` never exports `SSH_PUB_KEY`. The SSH-key-into-ignition code path in `patch_appliance.sh` is dead code.

---

### 22. `generate_appliance.sh:67,71` -- `podman run -it` requires a TTY

Both `sudo podman run` commands use `-it`. Fails or warns in CI/cron/non-interactive contexts.

---

### 23. `generate_config_image.sh:31` -- Default work directory nests `configimage/configimage/`

When `$2` is not provided, `config_image_dir` defaults to `${SCRIPTDIR}/configimage`. Since `SCRIPTDIR` is already `configimage/`, the actual path becomes `configimage/configimage/`.

---

### 24. `patch_appliance.sh:247` -- Hardcoded cluster identity duplicates YAML config sources

`rendezvous_ip`, `cluster_name`, and `base_domain` are hardcoded. If someone updates `agent-config.yaml` or `install-config.yaml.base` but not this script, `/etc/hosts` entries and DNS resolution break.

---

### 25. `patch-installer-config.sh:28-36` -- Silent fallthrough if `load-config-iso` never completes

The 60-retry loop (5min) has no failure log if exhausted. The script then proceeds to modify `assisted-service.env`, which may be in an intermediate state -- a race condition that can produce a corrupt env file.

---

### 26. Inconsistent `HOST_VF` defaults across scripts

| Script | Default | Interface |
|--------|---------|-----------|
| `can_start.sh:17` | `eno12399np0` | PF (SR-IOV physical function) |
| `setup-underlay.sh:88` | `eno12399v2` | VF2 (host virtual function) |
| `openperouter-node-index.sh:7` | `eno12399v2` (plus extra `}`) | VF2 (host VF) |

Since `vpn-setup.env` does not define `HOST_VF`, each script falls through to its own default. `can_start.sh` checks NM migration on the PF, while the other two look for the host IP on VF2.

---

## LOW Severity

### 27. `grout-bind.sh:31` -- `SECONDS` under `#!/bin/sh` shebang

`SECONDS` is a bash-ism that auto-increments. Under POSIX `sh`, it stays 0 and the 120s timeout never fires. Works on CoreOS only because `/bin/sh` is symlinked to bash.

### 28. `set-hostname.sh:45` -- Case-sensitive MAC grep

`ip address` outputs lowercase MACs; hostnames filenames may be uppercase. `grep` without `-i` won't match.

### 29. `grout-bind@.service:5-6` -- Redundant `Requires=` + `Wants=` for the same units

`Requires=` is strictly stronger than `Wants=`. Having both is noise.

### 30. `setup-underlay.sh:50` -- `TRUNK_VLAN` defined but unused

Dead code. `TRUNK_VLAN` is independently re-derived in `setup-network.sh`.

### 31. `setup-underlay.sh:130` -- ISIS NET system-ID uses decimal

`printf '%04d'` produces decimal digits, but ISIS system-ID fields are conventionally hex. Functionally correct but confusing during troubleshooting.

### 32. `grout-daemonset.yaml:98` -- Metrics sidecar uses mutable `:latest` tag

```yaml
image: docker.io/alpine/socat:latest
```

All other images are pinned to a specific SHA. Mutable tag breaks in air-gapped environments.

### 33. Worker butane has no `kernel_arguments`

Master butane configures serial console (`console=ttyS0,115200n8`). Workers missing it makes debugging boot failures harder on identical hardware.

### 34. `registry.bu:68` -- Non-absolute path in `ExecStartPre`

`ExecStartPre=mkdir -p /media/iso` should be `/usr/bin/mkdir`. systemd requires absolute paths for executables.

### 35. `install-config.yaml.base:15` -- Cluster name `sno-lab` misleading for 3-node cluster

`controlPlane.replicas: 3` with 3 hosts, but named `sno-lab` (Single Node OpenShift).

### 36. `can_start.sh` deployed to two paths

Same script at `/usr/local/bin/can_start.sh` and `/var/lib/openperouter/can_start.sh`. Maintenance risk if one is updated without the other.

### 37. `setup-local-registry.sh:30-31` -- Non-atomic `/etc/hosts` update

`sed -i` delete then `echo >>` append has a window where the hostname is unresolvable.

### 38. `grout-bind.sh:39,57` -- Unquoted variable expansions

`$netdev` and inner `$(readlink ...)` are unquoted. Edge-case breakage risk.

### 39. VLAN ID 42 hardcoded in two separate files

`setup-underlay.sh:50` and `setup-network.sh:42,64` both hardcode VLAN 42 with no configuration variable.

---

## Documentation vs Code Drift

### 40. Architecture doc references `sr0 dummy interface`

The doc says `setup-underlay.sh` creates an `sr0 dummy interface in FRR namespace for SRv6`. The code does not create any sr0 dummy -- it configures SRv6 addresses directly on `$UNDERLAY_NIC` via grcli.

### 41. Architecture doc systemd ordering diagram is misleading

The diagram shows `can_start.sh` directly above `grout-bind@` services, implying it gates them. But `grout-bind@.service` does not use `can_start.sh`. Only `setup-underlay.service` and the controller container run `can_start.sh`.

---

## Cleanup

### 42. Unused environment variables in `vpn-setup.env`

Three variables defined but never consumed:
- `VRF_TABLE=1100` -- `setup-network.sh` creates VRF via grcli with no table ID
- `VXLAN_PORT=4789` -- never referenced
- `VTEP_INTERFACE=lo` -- never referenced

### 43. `apply-manifests.sh` applies `namespace.yaml` twice

Line 42 applies it explicitly, then line 44 applies everything in the directory (including it again). Idempotent but redundant.
