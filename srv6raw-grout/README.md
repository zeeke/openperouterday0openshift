# OpenPERouter — SRv6 + Grout DPDK Deployment

Deploy OpenPERouter on bare-metal OpenShift using grout as the DPDK
dataplane. ISIS provides the underlay, SRv6 handles north-south L3VPN,
and EVPN/VXLAN provides east-west L2 bridging between nodes.

```
           ┌─────────────┐
           │  SRv6 gateway│
           │  (external)  │
           └──────┬───────┘
                  │  ISIS + SRv6 L3VPN
       ┌──────────┼──────────┐
       │          │          │
  ┌────┴───┐ ┌───┴────┐ ┌───┴────┐
  │master-0│ │master-1│ │master-2│  ...
  │  (RR)  │ │        │ │        │
  └────────┘ └────────┘ └────────┘
       ◄── EVPN / VXLAN (L2VPN) ──►
           reflected by master-0
```

## What to configure

Only two files need to be tuned per deployment:

### `configimage/openperouter.env`

Central configuration for the entire cluster. Contains all tunable
parameters: BGP AS, ISIS area, SRv6 gateway address, VRF/VNI settings,
grout resources, and address format strings that define the per-node
addressing scheme. Every variable is documented inline.

Address derivation is automatic: at boot, `perouter-host-dispatch.sh`
reads the host VF's last IPv4 octet and expands the `_FMT` format
strings (printf-style, `%d` for IPv4, `%x` for IPv6 hex groups) to
produce all per-node addresses (Router ID, loopbacks, SRv6 locator,
ISIS NET).

### `configimage/agent-config.yaml`

Per-node hardware configuration for the OpenShift agent-based installer:
MAC addresses, SR-IOV VF layout, IP assignments, and nmstate dispatch
scripts that bind VFs to the perouter namespace at boot.

Each node needs:

- Two PFs with `total-vfs: 16` and `mtu: 1800`
- VF0 of each PF: dispatch calls `perouter-bind.sh` to bind for grout
- VF1 of PF0: host VF (VLAN 42), dispatch calls
  `perouter-host-dispatch.sh` to derive addresses
- VF2+: available for pod workloads

## How it works at boot

```
nmstate (agent-config.yaml)
  ├─ PF activation: creates VFs, sets MTU 1800
  ├─ VF0 dispatch: perouter-bind.sh moves VF to perouter netns
  └─ VF1 dispatch: perouter-host-dispatch.sh derives addresses
grout.service
  └─ setup-underlay.service: creates grout ports from /run/perouter-bind/*
     └─ setup-network.service: creates VRF, VXLAN, bridge, addresses
        └─ generate-config.service: renders FRR template
           └─ bridge-refresher.service: adds VLAN port, pings VIPs
```

No dynamic NIC detection scripts. No systemd template units for VF
binding. Everything is driven by nmstate dispatch and static systemd
services.

## FRR configuration

Two templates in `configimage/extras/`:

- `openpe_evpn.yaml_rr.template` — route reflector: peers with the
  SRv6 gateway for L3VPN and reflects EVPN to all other nodes
- `openpe_evpn.yaml.template` — client: peers with the SRv6 gateway
  for L3VPN and with the RR for EVPN

`generate-config.sh` selects the template by comparing the node's last
octet against `RR_NODE_IDX` and renders it with `envsubst`.

## External peer (SRv6 gateway)

The `external-peer/` directory contains the FRR config and setup script
for the bastion that terminates SRv6 tunnels. It runs FRR in a separate
network namespace with a veth pair connecting VRF red to the default
namespace where DNS, NTP, and NAT run.

Run `external-peer/setup.sh` on the bastion to configure it.

## Switch

The `switch/` directory contains a Juniper QFX/EX configuration fragment
for the ISIS transit switch. All node-facing ports are point-to-point
ISIS Level-1 with jumbo MTU.

## Grout DPDK dataplane

Grout replaces the Linux kernel networking stack for the underlay and
overlay forwarding. It requires:

- **Hugepages**: 1G hugepages reserved via the performance profile
  (`GROUT_HUGEPAGES_1G` in openperouter.env)
- **Dedicated CPUs**: grout datapath threads are pinned to isolated
  cores (`GROUT_CPUS` in openperouter.env, `grout.slice` AllowedCPUs
  in the butane file)
- **SR-IOV VFs**: VF0 of each PF is bound to grout. For Mellanox (mlx5)
  NICs, the VF is moved to the perouter netns. For Intel (ice) NICs,
  the VF is unbound from the kernel driver and bound to vfio-pci.
- **PF MTU 1800**: set in agent-config.yaml on each PF. Required so
  VXLAN (50 bytes overhead) and SRv6 (48 bytes) encapsulated 1500-byte
  host frames fit without fragmentation.

The `perouter-bind.sh` script handles VF binding and is called
automatically by nmstate dispatch on VF activation. The grout container
starts after binding and `setup-underlay.sh` creates the grout ports
by iterating `/run/perouter-bind/*`.

FRR runs alongside grout in the same network namespace (routerpod) and
uses the `dplane_grout` zebra module to program routes directly into
grout's dataplane instead of the kernel.

## Building and deploying

```sh
# Build appliance ISO (first time only)
appliance/generate_appliance.sh <pull_secret> [ssh_key]

# Generate config-image ISO and boot all nodes
./deploy.sh <pull_secret> <idrac_host> [idrac_host...] [ssh_key]
```

The deploy script builds MachineConfig manifests from the butane file,
patches the appliance ISO, generates the config-image ISO, and boots
all servers via iDRAC virtual media.
