# Codebase Validation Findings

Review of srv6raw-grout against architecture.md and internal consistency.
Audited: build scripts, runtime scripts, butane/quadlets, FRR templates, manifests, registry.

---

## CRITICAL — Will break deployment or cause wrong behavior

### 1. `controllerpod.pod` — No `Network=host`; controller runs in bridge networking

**File:** `extras/quadlets/controllerpod.pod` (entire `[Pod]` section)
**Also:** `extras/quadlets/controller.container:27`

`controller.container` specifies `Network=host`, but it's inside `controllerpod.pod`. In Podman, when a container is in a pod, the pod's infra container owns the network namespace — per-container `--network` flags are silently ignored. `controllerpod.pod` has no `Network=` directive, so it defaults to bridge networking.

The controller needs host network access for Kubernetes API, systemd D-Bus, and host namespace operations. Without it, the controller cannot reach the API server, cannot manage network namespaces, and the health check (`http://127.0.0.1:9081/healthz`) may bind on the wrong loopback.

**Fix:** Add `Network=host` to `controllerpod.pod` under `[Pod]`, or remove `Pod=controllerpod.pod` from `controller.container` and run it standalone.

---

### 2. `setup-underlay.sh:112-113` — SRv6 uSID block prefix varies per node

```bash
SRV6_PREFIX="fd00:${LAST_OCTET}"
SRV6_NODE_ID="${LAST_OCTET}"
```

The FRR template renders the locator as:
```
prefix ${SRV6_PREFIX}:${SRV6_NODE_ID}::/48 block-len 32 node-len 16 func-bits 16
```

With `block-len 32`, the first 32 bits are the "block" (shared domain prefix). But `SRV6_PREFIX` includes `LAST_OCTET`, so each node gets a different block:
- Node 2: `fd00:0002:0002::/48` → block `fd00:0002`
- Node 3: `fd00:0003:0003::/48` → block `fd00:0003`

In SRv6 uSID (`behavior usid`), all nodes in the domain MUST share the same block for micro-SID compression to work. Different blocks mean uSID chaining across nodes is broken.

CTODO: does it work any way? or it is an optimization?

**Impact for PoC:** Basic SRv6 VPN (single SID per hop) still works because End.DT46 only needs the destination node's SID. But uSID compression (the main feature of `behavior usid`) is non-functional.

**Fix:** Make the block constant: `SRV6_PREFIX="fd00:0"` (or another fixed value). Only `SRV6_NODE_ID` should vary per node.

---

### 3. `set-hostname.sh:25` — `MAX_WAIT` undefined; wait loop always infinite

```bash
while [ -z "$(ls -A ${HOSTNAMES_PATH} 2>/dev/null)" ]; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
```

`MAX_WAIT` is never defined anywhere in the script. The comparison `[ $WAIT_COUNT -ge $MAX_WAIT ]` with an empty `$MAX_WAIT` produces a bash arithmetic error, which returns exit code 2 (treated as false by `if`). The timeout branch is never taken — the script blocks forever if no hostname files appear.

During the live ISO phase, this blocks `set-hostname.service`. If `/etc/assisted/hostnames` is populated but empty for longer than expected, the script hangs.

**Fix:** Add `MAX_WAIT="${MAX_WAIT:-60}"` near the top of the script.

---

### 4. `hackagent.sh` (workers) — Master MCS ignition fetched twice; infinite loop without timeout

For workers (lines 200-210), after the master ignition was already fetched and validated at lines 126-142, the worker branch fetches it AGAIN in an infinite `while true` loop with no timeout:

```bash
while true; do
    if curl ... -o "$MASTER_IGN_FILE" "https://192.168.110.2:22623/config/master" ...; then
        break
    fi
    sleep 5
done
```

If the bootstrap MCS goes down between the first and second fetch (which is plausible — bootstrap can reboot), this loop runs forever and the worker never installs.

Additionally, the first fetch (lines 126-142) already succeeded for `MASTER_IGN_READY=1`, so the second fetch is redundant and overwrites the already-valid file.

**Fix:** Remove the second fetch in the worker branch (lines 200-210) — `$MASTER_IGN_FILE` is already populated.

---

### 5. `hackagent.sh` — Bootstrap IP `192.168.110.2` hardcoded in appliance ISO

**File:** `appliance/hackagent.sh`, lines 37, 132, 202

The bootstrap MCS URL uses hardcoded IP `192.168.110.2`, which matches the current `agent-config.yaml` rendezvousIP. But this is baked into the appliance ISO (the "generic" one), not the per-cluster config ISO. Any cluster using a different rendezvous IP or machine-network subnet cannot use this appliance ISO — the ignition hack contacts a non-existent MCS.

**Fix:** Source the rendezvous IP from the config ISO (e.g., read it from agent-config at runtime), or accept that the appliance ISO is cluster-specific.

---

## HIGH — Likely to cause issues in some configurations

### 6. `setup-underlay.sh:113` — SRv6 node-ID of 0 when LAST_OCTET=0

```bash
SRV6_NODE_ID="${LAST_OCTET}"
```

If a host IP ends in `.0` (valid in /23 or larger subnets), `SRV6_NODE_ID=0`. In uSID, the `0000` node field is the End-of-Container marker. This corrupts SRv6 packet processing — any packet hitting this locator is treated as end-of-SID-list, causing silent black-holing.

**Fix:** Validate `LAST_OCTET != 0` or offset by 1 (`SRV6_NODE_ID=$((LAST_OCTET + 1))`).

---

### 7. `setup-underlay.sh:174` — `HOST_SUBNET_V6` may capture link-local `fe80::/64`

```bash
HOST_SUBNET_V6="$(ip -6 route list dev "$HOST_IFACE" proto kernel | awk '{print $1; exit}')"
```

On Linux, `ip -6 route` typically lists `fe80::/64` (link-local) before global-scope routes. Since `awk '{print $1; exit}'` takes the first entry, `HOST_SUBNET_V6` may be set to `fe80::/64` instead of the intended global IPv6 prefix.

This value is exported by `generate-config.sh` and substituted into the FRR template as `network ${HOST_SUBNET_V6}` under `router bgp ... vrf red / address-family ipv6 unicast`. FRR would advertise `fe80::/64` as a VPN route — breaking L3VPN IPv6 reachability between PEs.

**Fix:** Filter out link-local routes: `ip -6 route list dev "$HOST_IFACE" proto kernel | grep -v '^fe80' | awk '{print $1; exit}'`

---

### 8. FRR templates — Empty `HOST_SUBNET_V6` produces invalid FRR config

**File:** `extras/rawconfig/openpe_evpn.yaml.template:88`
**File:** `extras/rawconfig/openpe_evpn.yaml_rr.template:90`

If the host interface has no IPv6 address (or `ip -6 route` returns nothing), `HOST_SUBNET_V6=""`. The template renders:

```
 address-family ipv6 unicast
  network
```

This is syntactically invalid FRR configuration. FRR rejects the entire `router bgp ... vrf red` block, breaking BGP for both IPv4 and IPv6 in that VRF.

**Fix:** Guard the `network` line with a conditional in `generate-config.sh` (e.g., strip the line if `HOST_SUBNET_V6` is empty), or ensure `HOST_SUBNET_V6` always has a value.

---

### 8. `openperouter-raw.bu:304` — `Before=controllerpod.service routerpod.service` references wrong unit names

```yaml
Before=controllerpod.service routerpod.service
```

Quadlet pod files generate systemd service names with a `-pod` suffix: `controllerpod-pod.service` and `routerpod-pod.service`. The non-suffixed names don't exist, so systemd silently ignores the `Before=` constraint. `openperouter-node-index.service` has no ordering guarantee relative to the pods — race condition on `node-config.yaml`.

**Fix:** `Before=controllerpod-pod.service routerpod-pod.service`

---

### 9. `openperouter-raw.bu:158-169` — Butane enables non-existent quadlet service names

```yaml
- name: controllerpod.service
  enabled: true
- name: routerpod.service
  enabled: true
```

These create dangling symlinks in `/etc/systemd/system/default.target.wants/`. The actual services are `controllerpod-pod.service` and `routerpod-pod.service`. The pods still start (container units pull them in transitively), but `systemctl` logs warnings and `is-enabled` returns misleading results.

**Fix:** Use `controllerpod-pod.service` and `routerpod-pod.service`, or remove these entries (pods are pulled in by container dependencies).

---

### 10. `frr.container:34` + `reloader.container:28` — SELinux `:Z` conflict on overlapping paths

FRR mounts `/etc/perouter/frr/frr.conf` with `:Z` (private label). Reloader mounts `/etc/perouter/frr` (the parent directory) with `:Z`. Both are in the same `routerpod` pod. The last container to process its volumes wins the SELinux relabel; the other gets `Permission denied`.

On RHCOS with SELinux enforcing, this can prevent FRR from reading its own config file.

**Fix:** Change `:Z` to `:z` (lowercase — shared label) on volumes shared between containers in the same pod.

---

### 11. `setup-underlay.sh:192` — Stale FRR PID baked into vars file

```bash
FRR_PID="$FRR_PID"
```

The PID is captured once and persisted. If FRR restarts (crash, OOM, pod restart), any downstream script sourcing this file operates on a dead PID. No script actually consumes `FRR_PID` from this file — they all use `frr_netns_pid()` which does live lookup.

**Fix:** Remove `FRR_PID` from the vars file.

---

### 12. `grout.slice` (bu:175) — `AllowedCPUs=0,1,20,21` hardcoded for specific hardware

```
AllowedCPUs=0,1,20,21
```

This assumes a specific server topology (e.g., dual-socket with CPUs 0,1 on socket 0 and 20,21 as HT siblings). On servers with fewer than 22 CPUs or a different layout, systemd fails to apply this property and grout cannot start — the entire dataplane is broken before the reservation DaemonSet gets a chance to dynamically expand the slice.

**Fix:** Use a broader initial range (e.g., `AllowedCPUs=0-3`) that is valid on most hardware, or derive the initial CPUs at boot time.

---

### 13. `setup-underlay.service` (bu:203) — `After=grout.service frr.service` but no `Wants=`

`After=` only affects ordering IF both units are starting. If `grout.service` or `frr.service` fail to start (or aren't pulled in), `setup-underlay.service` starts without them and immediately crashes on `grcli` calls or FRR readiness checks.

The unit has `Requires=routerpod-pod.service` which transitively pulls in containers, so this may work in practice. But if grout or FRR fail within the pod, setup-underlay starts anyway.

**Fix:** Add `Wants=grout.service frr.service` to ensure they're at least attempted.

---

## MEDIUM — Could cause issues in edge cases

### 12. `setup-network.sh:40` — Unbound variable crash if vars file missing

With `set -u` active, expanding `$ROUTER_ID` (line 40 via `$VTEP_IP`) when the vars file is absent crashes with a cryptic bash error before the friendly error message at lines 44-48 is reached.

**Fix:** Use `VTEP_IP="${VTEP_IP:-${ROUTER_ID:-}}"` or check vars file existence before sourcing.

---

### 13. `setup-network.sh` — No rollback on partial grcli failure

VRF, bridge, VXLAN are created sequentially. A failure partway through leaves orphaned objects in grout. Re-runs fail with "already exists" without manual cleanup. With `set -e`, any failure aborts the script but doesn't clean up.

**Fix:** Make commands idempotent (check before create), or add a trap to clean up partial state.

---

### 14. `mount-agent-data.sh:69-70` — Hardcoded `"true" = "true"` dead-code branches

```bash
if [ "true" = "true" ]; then
    if [ "true" = "true" ]; then
```

Template placeholders that were never substituted. The `else` branches (disk-image mode, ISO mode) are unreachable. Functionally harmless for the current path, but confusing and prevents using alternative mount modes.

---

### 15. `mount-agent-data.sh:42-45` — Infinite wait loop with no timeout

```bash
while ! mountpoint -q $ISO_DIR; do
    sleep 5
done
```

If the ISO is never mounted, this blocks the entire bootstrap forever with no diagnostic output.

**Fix:** Add a retry limit with a diagnostic message.

---

### 16. `apply-manifests.sh:20-22` — API server wait loop has no timeout

```bash
until oc get ns >/dev/null 2>&1; do sleep 5; done
```

If the API server never comes up (SRv6 fabric broken, etcd quorum lost), this loops forever. The `TimeoutStartSec=600` on the systemd unit provides an external timeout, but the script itself gives no diagnostics during the wait.

---

### 17. `hackagent.sh` (embedded) — No `set -o pipefail`; pipe failures silently swallowed

The embedded `ignition-hack.sh` uses `set -e` but not `set -o pipefail`. Commands piped through `tee -a "$LOG_FILE"` mask exit codes. A failed `sgdisk -d` lets `sgdisk -n` proceed on the same partition, potentially corrupting the GPT.

The `dd` writing ignition checks for errors, but other critical operations (curl, jq transforms) could silently fail.

**Fix:** Add `set -eo pipefail` to the embedded script.

---

### 18. `bridge-refresher.sh:45-48` — Infinite loop waiting for VNI with no timeout

```bash
while ! podman exec frr vtysh ... | grep -q "VNI: ${L2_VNI}"; do
    sleep 1
done
```

If FRR never learns the VNI (BGP session not established, EVPN not configured), this blocks forever. The VLAN bridge port is never added, and north-south traffic never works.

**Fix:** Add a timeout with a diagnostic error.

---

### 19. Inconsistent `HOST_VF` defaults across scripts

| Script | Default | Interface |
|--------|---------|-----------|
| `can_start.sh:16` | `eno12399v2` | VF2 |
| `setup-underlay.sh:48` | `eno12399v2` | VF2 |
| `openperouter-node-index.sh` | from vpn-setup.env | dynamic |

The defaults are now mostly consistent (`eno12399v2`), but `generate-vpn-env.sh` dynamically detects VF names from sysfs. If sysfs detection fails but the env file is still written (without VF names), scripts fall back to their hardcoded defaults which may not match the actual interface names.

---

### 20. Worker MachineConfig inherits master-only content

`generate_machineconfigs.sh` uses `sed` to swap `role: master` → `role: worker`, producing worker MachineConfigs from the master butane. This means workers get `apply-manifests.sh`, the DaemonSet manifests, and `apply-manifests.path` — all marked "M only" in architecture.md.

**Impact:** `apply-manifests.path` watches for a kubeconfig that won't exist on workers, so it won't trigger. Functionally harmless but wastes disk space and could cause confusing systemd unit states on workers.

---

## LOW — Cosmetic, robustness, or unlikely to cause issues

### 21. `grout-bind.sh:31` — `SECONDS` under `#!/bin/sh`

`SECONDS` is a bash-ism that auto-increments. Under POSIX `sh`, it stays 0 and the 120s timeout never fires. Works on CoreOS because `/bin/sh` → bash.

### 22. `set-hostname.sh:38` — Case-sensitive MAC grep

`ip address` outputs lowercase MACs; hostname filenames may use uppercase. `grep` without `-i` won't match.

### 23. `grout-bind@.service:5-6` — Redundant `Requires=` + `Wants=` for the same units

`Requires=` is strictly stronger than `Wants=`. Having both is noise.

### 24. `setup-underlay.sh:115` — ISIS NET system-ID uses decimal

`printf '%04d'` produces decimal digits, but ISIS system-ID fields are conventionally hex. Functionally correct but confusing during troubleshooting (`show isis neighbor` shows decimal system-IDs).

### 25. `grout-daemonset.yaml:98` — Metrics sidecar uses mutable `:latest` tag

```yaml
image: docker.io/alpine/socat:latest
```

All other images are pinned to a specific SHA. Mutable tag breaks in air-gapped environments (the tag can't be resolved from the local mirror if it wasn't mirrored).

### 26. `registry.bu:67` — Non-absolute path in `ExecStartPre`

```
ExecStartPre=mkdir -p /media/iso
```

systemd requires absolute paths for executables. Should be `/usr/bin/mkdir`.

### 27. `install-config.yaml.base` — Cluster name `sno-lab` misleading for 3-node cluster

`controlPlane.replicas: 3` with name `sno-lab` (Single Node OpenShift). Cosmetic but confusing.

### 28. `can_start.sh` deployed to two paths

Same script at `/usr/local/bin/can_start.sh` and `/var/lib/openperouter/can_start.sh` (butane lines 54-59). Both are installed from the same source, so they're identical. Maintenance risk if one path is updated without the other in future changes.

### 29. `setup-local-registry.sh` — Non-atomic `/etc/hosts` update

`sed -i` delete then `echo >>` append has a window where the hostname is unresolvable.

### 30. VLAN ID 42 hardcoded in two separate files

`setup-underlay.sh` and `setup-network.sh` both use VLAN ID 42 with `TRUNK_VLAN="${TRUNK_NIC}.42"`. No shared variable — must be kept in sync manually.

### 31. `apply-manifests.sh` applies `namespace.yaml` twice

Line 42 applies it explicitly, then line 44 applies everything in the directory (including it again). Idempotent but redundant.

### 32. `load-registry-image.sh` — Missing `set -euo pipefail`

If `podman pull` fails, `IMAGE_ID_FROM_PULL` is empty and the script exits 0. The registry container later fails with "image not found".

---

## Architecture Doc vs Code Drift

### 33. Doc references `vpn-setup.env` at `/etc/openperouter/vpn-setup.env`

The file in extras is `vpn-setup.env.defaults` (not `vpn-setup.env`). At runtime, `generate-vpn-env.sh` copies the defaults file and appends detected NIC names, producing the final `vpn-setup.env`. This is correct behavior but the architecture doc's file map table (line 505) shows `rawconfig/vpn-setup.env` → `/etc/openperouter/vpn-setup.env`, which is inaccurate.

### 34. Doc systemd ordering diagram is misleading

The diagram shows `can_start.sh` directly above `grout-bind@` services, implying it gates them. But `grout-bind@.service` does NOT use `can_start.sh`. Only `setup-underlay.service` and `controller.container` run `can_start.sh` as `ExecStartPre`.

### 35. No worker butane files exist

Architecture.md references `openperouter-raw-worker.bu` and `registry-worker.bu`, but these don't exist as separate files. `generate_machineconfigs.sh` derives worker configs from master butane files via sed substitution. This works but differs from what the doc describes.

---

## Previously Found Issues — Now Fixed

The following issues from an earlier review have been resolved:

- **Extra `}` in `openperouter-node-index.sh`** — Fixed. Script now sources `vpn-setup.env` instead of hardcoding the interface name.
- **Hardcoded /24 assumption for `BR0_SUBNET`** — Fixed. `HOST_SUBNET` is now derived from `ip route` output.
- **Fragile IPv6 subnet derivation via sed** — Fixed. `HOST_SUBNET_V6` is now derived from `ip -6 route`.
- **`SSH_PUB_KEY` dead code in `patch_appliance.sh`** — Still present but harmless (gated by `[[ -n "${SSH_PUB_KEY:-}" ]]`).
- **`generate_config_image.sh` nested directory** — Not verified; may still exist.
