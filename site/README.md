# Sites

Each directory here holds the files that describe a site. Its `configimage/`
and `extras/` folders mirror the `srv6fullconfig/` layout, so copying them over
`srv6fullconfig/` replaces the defaults with the site configuration. Run the
commands below from the repository root.

## VM lab (`vmlab`)

The defaults in `srv6fullconfig/configimage/` and
`srv6fullconfig/extras/config/` describe the VM lab with the kernel datapath.
After switching to another site, restore them. `git clean` removes the files the other site added, which the
build would otherwise still compile:

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
