# Sites

Each directory here holds the files that describe a site. Its `configimage/`
and `extras/` folders mirror the `srv6fullconfig/` layout, so copying them over
`srv6fullconfig/` replaces the defaults with the site configuration. Run the
commands below from the repository root.

## VM lab (`vmlab`)

The defaults in `srv6fullconfig/configimage/` and
`srv6fullconfig/extras/config/` describe the VM lab with the kernel datapath.
After switching to another site, restore them. `git clean` removes the files the other site added, such as
the `nfv` VF aliases, which the build would otherwise still compile:

```bash
git checkout -- srv6fullconfig/
git clean -f srv6fullconfig/
```

For the Grout datapath, also copy the `grout` variant over the defaults and
build both ISOs with `GROUT_DATAPATH=1`:

```bash
cp -r site/vmlab/grout/* srv6fullconfig/
```

The site also holds the tooling that runs the lab on a libvirt host:

| File | Purpose |
|------|---------|
| `lab-up.sh` | Creates the networks, the external FRR container and the VMs, booting them from the two ISOs |
| `lab-down.sh` | Removes everything `lab-up.sh` created and restores the host sysctls |
| `externalfrr/` | External FRR container (TOR) with its FRR, dnsmasq and chrony configuration |
| `xml/` | libvirt templates for the networks and the VMs |

Build both ISOs, see the [`srv6fullconfig` README](../srv6fullconfig/README.md#building),
then start the lab:

```bash
sudo ./site/vmlab/lab-up.sh <appliance.iso> <config-image.iso>
```

To fit another cluster or fabric, edit these files:

| File | Purpose |
|------|---------|
| `configimage/agent-config.yaml` | Hosts, NICs, IP addressing |
| `configimage/install-config.yaml.base` | Cluster name, machine network, VIPs |
| `extras/config/openpe_master.yaml` | OpenPERouter configuration for the masters |
| `extras/config/openpe_worker.yaml` | OpenPERouter configuration for the workers |

## Hardware with the Grout datapath (`nfv`)

Copy the site over `srv6fullconfig/`:

```bash
cp -r site/nfv/configimage site/nfv/extras srv6fullconfig/
```

Then adapt the copied files to the cluster and the fabric:

| File | Purpose |
|------|---------|
| `configimage/agent-config.yaml` | Hosts, NICs, SR-IOV VFs, IP addressing |
| `extras/config/openpe_master.yaml`, `extras/config/openpe_worker.yaml` | OpenPERouter configuration, with the underlay on the `underlayvf` VF |
| `configimage/openperouter-master-vf-aliases.bu`, `configimage/openperouter-worker-vf-aliases.bu` | Aliases (`underlayvf`, `trunkvf`) matching the VFs from `agent-config.yaml` |

Also adapt the CPU partitioning, hugepages and NUMA settings in
`configimage/performance-profile-master.yaml` and
`configimage/performance-profile-worker.yaml`.
The Grout CPU reservation pods in
`srv6fullconfig/extras/config/pod-grout-reservation-*.yaml` refer to the
performance profiles by name, through their runtime class, so update them if
you rename the profiles.

Build both ISOs with `GROUT_DATAPATH=1`, see the [`srv6fullconfig` README](../srv6fullconfig/README.md#building).
The appliance ISO embeds the master configuration, so rebuild both ISOs after
changing the site files.

## Bare-metal lab (`baremetal`)

Grout datapath for the physical lab that matches the kernel deployment in
`pe_kernel` (same cluster addressing and TOR peering). Management stays on
`bond1.16`; SR-IOV on Mellanox `eno12399np0` with onboard VF names
(`eno12399v0` / `v1` → `underlayvf` / `trunkvf`). See
[`baremetal/README.md`](baremetal/README.md) for hardware notes and AMD IOMMU.

Restore defaults before switching sites (same as above), then copy:

```bash
cp -r site/baremetal/configimage site/baremetal/extras srv6fullconfig/
```

| File | Purpose |
|------|---------|
| `configimage/agent-config.yaml` | SR-IOV VFs, lab IPs, `bond1.16` management |
| `configimage/install-config.yaml.base` | Cluster name, VIPs, worker count |
| `configimage/openperouter-*-vf-aliases.bu` | `underlayvf` / `trunkvf` via `ID_NET_NAME_ONBOARD` |
| `configimage/performance-profile-*.yaml` | CPU isolation, hugepages (`amd_iommu=on`) |
| `configimage/grout-kargs-*.bu` | Install-time IOMMU and hugepage kargs (AMD) |
| `extras/config/openpe_master.yaml`, `openpe_worker.yaml` | Grout OpenPERouter static config |

Build both ISOs with `GROUT_DATAPATH=1`, see the
[`srv6fullconfig` README](../srv6fullconfig/README.md#building). Rebuild both
ISOs after any change under `site/baremetal/`.

**Note:** `srv6fullconfig/appliance/patch_appliance.sh` still injects
`intel_iommu=on` into the appliance ISO at build time; on AMD hosts adjust
appliance kargs manually or patch that script when building for this site.

## Adding a site

Create a directory here with `configimage/` and `extras/` folders that hold
only the files that differ from the defaults. Keep any other files, such as
lab tooling, outside those folders so the copy command leaves them alone. The
build scripts pick up every `configimage/*.bu` file:

- The config-image ISO compiles all of them into MachineConfigs.
- The appliance ISO compiles only the `openperouter-master*.bu` files, because
  it only needs the OpenPERouter host stack for the first boot. Keep
  MachineConfig-only settings, such as `openshift.kernel_arguments`, in files
  with another name (e.g. `grout-kargs-master.bu`).
- Files with `grout` in their name are only compiled when `GROUT_DATAPATH` is
  set.
