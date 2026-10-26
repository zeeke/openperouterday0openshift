# Bare-metal lab (Grout datapath)

Site overlay for the same physical lab used with the kernel datapath in
`pe_kernel` (`srv6fullconfig`). Targets **Grout** on Mellanox **`eno12399np0`**
with SR-IOV VFs, while keeping **management on `bond1.16`** and preserving
underlay addressing/peering from the kernel deployment.

## Hardware (validated on `master-0`)

| Item | Value |
|------|--------|
| CPU | AMD EPYC 9654P, 1 socket, 192 logical CPUs (NUMA node 0 only) |
| PF | `eno12399np0` (`numa_node` 0) |
| VF 0 | `eno12399v0` → `underlayvf` (ISIS / SRv6 to TOR) |
| VF 1 | `eno12399v1` → `trunkvf` (accelerated L2 toward perouter) |
| VF 2 | `eno12399v2` (host / OpenShift machine network) |
| udev match | `ID_NET_NAME_ONBOARD=eno12399v0` / `v1` (not `ens1f0v0` slot names) |
| IOMMU | **AMD** — site profiles must use `amd_iommu=on`, not `intel_iommu=on` |

VLAN **42** on the host VF is an on-node convention (agent-config + openpe
`sriovVFPair`); TOR underlay on VF 0 stays **untagged** like the kernel PF.

## Rollout plan (one change per review)

| Step | Change | Status |
|------|--------|--------|
| 1 | This README (scope, hardware, phased plan) | done |
| 2 | `configimage/openperouter-*-vf-aliases.bu` (onboard `eno12399v0` / `v1`) | done |
| 3 | `configimage/performance-profile-master.yaml` (AMD, NUMA 0, CPU/hugepages) | done |
| 4 | `configimage/performance-profile-worker.yaml` | done |
| 5 | `configimage/grout-kargs-*.bu` (AMD IOMMU for install-time kargs) | done |
| 6 | `configimage/install-config.yaml.base` (from `pe_kernel` lab) | done |
| 7 | `configimage/agent-config.yaml` (SR-IOV + lab IPs + `bond1.16` mgmt) | done |
| 8 | `extras/config/openpe_master.yaml` (Grout/NFV shape + lab peers) | done |
| 9 | `extras/config/openpe_worker.yaml` | done |
| 10 | Link this site from `site/README.md` | done |

## Apply site (after all steps)

From the repository root:

```bash
cp -r site/baremetal/configimage site/baremetal/extras srv6fullconfig/
GROUT_DATAPATH=1 ./srv6fullconfig/appliance/generate_appliance.sh <pull_secret>
GROUT_DATAPATH=1 ./srv6fullconfig/configimage/generate_config_image.sh <pull_secret>
```

Rebuild **both** ISOs after any edit under `site/baremetal/`.

## Restore defaults

```bash
git checkout -- srv6fullconfig/
git clean -f srv6fullconfig/
```

## Layout (when complete)

```text
site/baremetal/
  README.md
  configimage/
    agent-config.yaml
    install-config.yaml.base
    openperouter-master-vf-aliases.bu
    openperouter-worker-vf-aliases.bu
    performance-profile-master.yaml
    performance-profile-worker.yaml
    grout-kargs-master.bu
    grout-kargs-worker.bu
  extras/config/
    openpe_master.yaml
    openpe_worker.yaml
```
