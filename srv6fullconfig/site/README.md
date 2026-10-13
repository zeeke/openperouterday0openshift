# Sites

The files in `configimage/` and `extras/config/` describe the VM lab with the
kernel datapath. Each directory here holds the files that describe another
site. It mirrors the `srv6fullconfig/` layout, so copying it over the
repository replaces the defaults with the site configuration.

## Kernel datapath

Edit these files in place to fit the cluster and the fabric:

| File | Purpose |
|------|---------|
| `configimage/agent-config.yaml` | Hosts, NICs, IP addressing |
| `configimage/install-config.yaml.base` | Cluster name, machine network, VIPs |
| `extras/config/openpe_master.yaml` | OpenPERouter configuration for the masters |
| `extras/config/openpe_worker.yaml` | OpenPERouter configuration for the workers |

## Grout datapath (`grout-hw`)

From `srv6fullconfig/`, copy the site over the repository:

```bash
cp -r site/grout-hw/. .
```

Then adapt the copied files to the cluster and the fabric:

| File | Purpose |
|------|---------|
| `configimage/agent-config.yaml` | Hosts, NICs, SR-IOV VFs, IP addressing |
| `extras/config/openpe_master.yaml`, `extras/config/openpe_worker.yaml` | OpenPERouter configuration, with the underlay on the `underlayvf` VF |
| `configimage/openperouter-master-grout-hw.bu`, `configimage/openperouter-worker-grout-hw.bu` | Aliases (`underlayvf`, `trunkvf`) matching the VFs from `agent-config.yaml` |

Also adapt the CPU partitioning, hugepages and NUMA settings in
`configimage/performance-profile-master.yaml` and
`configimage/performance-profile-worker.yaml`.
`extras/config/workload-pod.yaml` refers to the master performance profile by
name, so update it if you rename the profile.

Build both ISOs with `GROUT_DATAPATH=1`, see the [main README](../README.md#building).
The appliance ISO embeds the master configuration, so rebuild both ISOs after
changing the site files.

## Adding a site

Create a directory here with the same layout as `srv6fullconfig/` and only the
files that differ from the defaults. The build scripts pick up every
`configimage/*.bu` file:

- The config-image ISO compiles all of them into MachineConfigs.
- The appliance ISO compiles only the `openperouter-master*.bu` files, because
  it only needs the OpenPERouter host stack for the first boot. Keep
  MachineConfig-only settings, such as `openshift.kernel_arguments`, in files
  with another name (e.g. `grout-kargs-master.bu`).
- Files with `grout` in their name are only compiled when `GROUT_DATAPATH` is
  set.
