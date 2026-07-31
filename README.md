# OpenPERouter on OpenShift — Day-0 Deployment

Day-0 deployment of [OpenPERouter](https://github.com/openshift/openperouter) on
bare-metal OpenShift clusters using the appliance installer. OpenPERouter is
baked into the appliance ISO and configured via MachineConfig, so networking is
ready from first boot — no post-install operators needed.

## Deployments

| Directory | Underlay | Overlay | Config method | Route distribution | Dataplane |
|-----------|----------|---------|---------------|--------------------|-----------|
| [`srv6raw/`](srv6raw/) | ISIS | SRv6 + VXLAN | Rawconfig (shell templates) | EVPN route reflector (master-0) | Kernel |
| [`srv6raw-grout/`](srv6raw-grout/) | ISIS | SRv6 + VXLAN | Rawconfig (shell templates) | EVPN route reflector (master-0) | Grout |
| [`evpnfullconfig/`](evpnfullconfig/) | eBGP | VXLAN only | Controller (`openpe_config.yaml`) | TOR distributes all routes | Kernel |

Each directory contains its own [TOPOLOGY.md](srv6raw/TOPOLOGY.md) with full addressing and peering details.

## How it works

1. **`appliance/generate_appliance.sh`** builds a RHCOS appliance ISO with
   OpenPERouter quadlets, registry mirrors, and DNS overrides embedded
2. **`configimage/generate_config_image.sh`** produces a config-image ISO with
   install-config, agent-config, and MachineConfig manifests (rendered from butane)
3. Nodes boot from the appliance ISO, mount the config-image, and install
   OpenShift with OpenPERouter networking active from the start

Both scripts take a pull secret file as the first argument. See each
deployment's README for build commands and configuration details.
