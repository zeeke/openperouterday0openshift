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
produce per-node addresses (Router ID, loopbacks, SRv6 locator,
ISIS NET). Underlay addresses are looked up from the
`UNDERLAY_ADDRESSES` table by hostname.

### `configimage/agent-config.yaml`

Per-node hardware configuration for the OpenShift agent-based installer:
MAC addresses, SR-IOV VF layout and IP assignments

Each node needs:

- VF0 of the underlay PF: used for fabric connection and for VLAN 
  connectivity to the host
- VF1 of underlay PF: host VF (VLAN 42). Must be configured as the 
  default gateway for the host networking.
- VF2+: available for pod workloads

### `configimage/performance-profile.yaml`

Node tuning for DPDK: reserves CPUs for platform use, isolates the
rest for grout and workloads, allocates 1G hugepages, enables
`iommu=pt` and `intel_iommu=on` for VFIO passthrough, and sets
single-NUMA-node topology policy.

## FRR configuration

Two templates in `configimage/extras/`:

- `openpe_evpn.yaml_rr.template` — route reflector: peers with the
  SRv6 gateway for L3VPN and reflects EVPN to all other nodes
- `openpe_evpn.yaml.template` — client: peers with the SRv6 gateway
  for L3VPN and with the RR for EVPN

`generate-config.sh` selects the template by comparing the node's last
octet against `RR_NODE_IDX` and renders it with `envsubst`.

## Grout DPDK dataplane

Grout replaces the Linux kernel networking stack for the underlay and
overlay forwarding. It requires:

- **Hugepages**: 1G hugepages reserved via the performance profile
  (`GROUT_HUGEPAGES_1G` in openperouter.env)
- **Dedicated CPUs**: grout datapath threads are pinned to isolated
  cores (`GROUT_CPUS` in openperouter.env, `grout.slice` AllowedCPUs
  in the butane file)
- **SR-IOV VFs**: VF0 of the underlay PF is bound to grout. For Mellanox (mlx5)
  NICs, the VF is moved to the perouter netns. For Intel (ice) NICs,
  the VF is unbound from the kernel driver and bound to vfio-pci.

The `perouter-bind.sh` script handles VF binding and is called
automatically by nmstate dispatch on VF activation. The grout container
starts after binding and `setup-underlay.sh` creates the grout ports
by iterating `/run/perouter-bind/*`.

FRR runs alongside grout in the same network namespace (routerpod) and
uses the `dplane_grout` zebra module to program routes directly into
grout's dataplane instead of the kernel.


## Building and deploying

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file>`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`

## Differences from `srv6raw/`

This variant replaces the Linux kernel networking stack with grout, a
DPDK userspace dataplane. The following are the key differences taken
from a master node.

### Systemd services

```console
# systemctl list-units '
...
bridge-refresher.service    loaded active running OpenPERouter Bridge Refresher
controller.service          loaded active running OpenPERouter Controller Container
controllerpod-pod.service   loaded active running OpenPERouter Controller Pod
frr.service                 loaded active running OpenPERouter FRR Container
generate-config.service     loaded active exited  OpenPERouter Configuration Generator
grout.service               loaded active running Grout DPDK Dataplane
reloader.service            loaded active running OpenPERouter FRR Reloader Container
routerpod-pod.service       loaded active running OpenPERouter FRR Router Pod
setup-network.service       loaded active exited  OpenPERouter Network Infrastructure Setup
setup-underlay.service      loaded active exited  OpenPERouter Underlay Setup (create grout ports)
grout.slice                 loaded active active  Slice /grout
```

### Grout interfaces

```console
# podman exec grout grcli interface
NAME          ID  FLAGS                        MODE    DOMAIN     TYPE    INFO
main           1  up running                   VRF     main       vrf     ip4 routes=65536 tbl8=256 ip6 routes=65536 tbl8=262144
underlay0      2  up running promisc allmulti  VRF     main       port    devargs=0000:c4:00.2 mac=a2:72:d3:2e:80:e1
red            3  up running                   VRF     red        vrf     ip4 routes=65536 tbl8=256 ip6 routes=65536 tbl8=262144
br-pe-210      4  up running                   VRF     red        bridge  members=2 flood learn
vni210         5  up running                   bridge  br-pe-210  vxlan   vni=210 local=10.0.0.3 encap_vrf=main
underlay0.42   6  up running promisc           bridge  br-pe-210  vlan    parent=underlay0 vlan_id=42
```

### Grout addresses

```console
# podman exec grout grcli address
IFACE      FAMILY  ADDRESS
underlay0  ipv4    10.0.0.3/32
underlay0  ipv4    192.168.136.22/25
br-pe-210  ipv4    192.168.110.1/24
underlay0  ipv6    fe80::a072:d3ff:fe2e:80e1/64
underlay0  ipv6    2600:52:7:136::22/64
underlay0  ipv6    fc00:0:3::1/128
underlay0  ipv6    fd00:3::1/128
br-pe-210  ipv6    fe80::4036:62ff:fe38:f4f1/64
br-pe-210  ipv6    fd00:110::1/64
```

### Grout nexthops

```console
# podman exec grout grcli nexthop
VRF   ID  ORIGIN  IFACE      TYPE        INFO
red   4   zebra   red        SRv6-local  behavior=end.dt46 flavor=next-csid block_bits=32 csid_bits=16 out_vrf=3
main  68  zebra   underlay0  L3          family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
main  69  zebra   underlay0  L3          family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  73  zebra   underlay0  SRv6        encap=h.encaps.red seglist=fd00:20:10:e003::
main  75  zebra   underlay0  SRv6        encap=h.encaps.red seglist=fd00:20:10:e002::
```

### Grout routes

```console
# podman exec grout grcli route
VRF   FAMILY  DESTINATION         ORIGIN  NEXT_HOP
main  ipv4    10.0.0.2/32         isis    type=L3 id=68 iface=underlay0 vrf=main origin=zebra family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
main  ipv4    10.0.0.3/32         link    type=L3 iface=underlay0 vrf=main origin=INTERNAL family=ipv4 addr=10.0.0.3/32 mac=a2:72:d3:2e:80:e1 flags=static local link
main  ipv4    10.0.0.4/32         isis    type=L3 id=68 iface=underlay0 vrf=main origin=zebra family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
main  ipv4    10.0.0.20/32        isis    type=L3 id=68 iface=underlay0 vrf=main origin=zebra family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
main  ipv4    192.168.135.0/25    isis    type=L3 id=68 iface=underlay0 vrf=main origin=zebra family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
main  ipv4    192.168.136.0/25    link    type=L3 iface=underlay0 vrf=main origin=INTERNAL family=ipv4 addr=192.168.136.22/25 mac=a2:72:d3:2e:80:e1 flags=static local link
main  ipv4    192.168.137.0/25    isis    type=L3 id=68 iface=underlay0 vrf=main origin=zebra family=ipv4 addr=192.168.136.1 state=reachable mac=c8:47:09:ab:80:66
red   ipv4    10.10.20.1/32       bgp     type=SRv6 id=75 iface=underlay0 vrf=main origin=zebra encap=h.encaps.red seglist=fd00:20:10:e002::
red   ipv4    192.168.110.0/24    link    type=L3 iface=br-pe-210 vrf=red origin=INTERNAL family=ipv4 addr=192.168.110.1/24 mac=42:36:62:38:f4:f1 flags=static local link
red   ipv4    192.168.177.0/25    bgp     type=SRv6 id=75 iface=underlay0 vrf=main origin=zebra encap=h.encaps.red seglist=fd00:20:10:e002::
main  ipv6    2600:52:7:135::/64  isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    2600:52:7:136::/64  link    type=L3 iface=underlay0 vrf=main origin=INTERNAL family=ipv6 addr=2600:52:7:136::22/64 mac=a2:72:d3:2e:80:e1 flags=static local link
main  ipv6    2600:52:7:137::/64  isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fc00:0:2::1/128     isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fc00:0:3::1/128     link    type=L3 iface=underlay0 vrf=main origin=INTERNAL family=ipv6 addr=fc00:0:3::1/128 mac=a2:72:d3:2e:80:e1 flags=static local link
main  ipv6    fc00:0:4::1/128     isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fc00:0:20::1/128    isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fd00:2::1/128       isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fd00:2:2::/48       isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fd00:3::1/128       link    type=L3 iface=underlay0 vrf=main origin=INTERNAL family=ipv6 addr=fd00:3::1/128 mac=a2:72:d3:2e:80:e1 flags=static local link
main  ipv6    fd00:3:3:2::/128    bgp     type=SRv6-local id=4 iface=red vrf=red origin=zebra behavior=end.dt46 flavor=next-csid block_bits=32 csid_bits=16 out_vrf=3
main  ipv6    fd00:4::1/128       isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fd00:4:4::/48       isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
main  ipv6    fd00:20:10::/48     isis    type=L3 id=69 iface=underlay0 vrf=main origin=zebra family=ipv6 addr=fe80::ca47:9ff:feab:8066 state=reachable mac=c8:47:09:ab:80:66
red   ipv6    fc00:10:20::1/128   bgp     type=SRv6 id=73 iface=underlay0 vrf=main origin=zebra encap=h.encaps.red seglist=fd00:20:10:e003::
red   ipv6    fd00:110::/64       link    type=L3 iface=br-pe-210 vrf=red origin=INTERNAL family=ipv6 addr=fd00:110::1/64 mac=42:36:62:38:f4:f1 flags=static local link
```

### Grout FDB

```console
# podman exec grout grcli fdb
BRIDGE     MAC                VLAN  IFACE         VTEP      FLAGS      AGE
br-pe-210  be:ff:60:a5:20:40        vni210        10.0.0.4  extern hw    8
br-pe-210  72:c5:d2:67:bc:f5        vni210        10.0.0.4  extern hw    0
br-pe-210  16:38:93:fa:c0:d8        vni210        10.0.0.2  extern hw    2
br-pe-210  42:36:62:38:f4:f1        br-pe-210               learn hw     0
br-pe-210  92:64:85:1f:5e:19        vni210        10.0.0.2  extern hw    0
br-pe-210  ca:e4:6f:2d:62:50        underlay0.42            learn hw     0
```

### FRR — ISIS adjacency

```console
# podman exec frr vtysh -c "show isis neighbor"
Area PE:
 System Id           Interface   L  State         Holdtime SNPA
 tor-sw-114-cisco    underlay0   1  Up            8        c847.09ab.8066
```

### FRR — BGP summary

```console
# podman exec frr vtysh -c "show bgp summary"
IPv4 VPN Summary:
BGP router identifier 10.0.0.3, local AS number 65500 VRF default vrf-id 0
BGP table version 0
RIB entries 3, using 456 bytes of memory
Peers 1, using 24 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
fc00:0:20::1    4      65500       113       113        9    0    0 01:47:54            2        1 N/A

IPv6 VPN Summary:
BGP router identifier 10.0.0.3, local AS number 65500 VRF default vrf-id 0
BGP table version 0
RIB entries 3, using 456 bytes of memory
Peers 1, using 24 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
fc00:0:20::1    4      65500       113       113        9    0    0 01:47:54            1        1 N/A
```

### FRR — EVPN summary

```console
# podman exec frr vtysh -c "show bgp l2vpn evpn summary"
L2VPN EVPN Summary:
BGP router identifier 10.0.0.3, local AS number 65500 VRF default vrf-id 0
BGP table version 0
RIB entries 7, using 1064 bytes of memory
Peers 1, using 24 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
fc00:0:2::1     4      65500       119       114       10    0    0 01:37:20            8        2 N/A
```

### FRR — EVPN VNI

```console
# podman exec frr vtysh -c "show evpn vni"
VNI        Type VxLAN IF              # MACs   # ARPs   # Remote VTEPs  Tenant VRF
210        L2   vni210                5        4        2               red
```

### FRR — zebra dplane providers

```console
# podman exec frr vtysh -c "show zebra dplane providers"
Zebra dataplane providers:
  zebra_dplane_grout (2): in: 152, q: 0, q_max: 18, out: 152, q: 0, q_max: 18
  Kernel (1): in: 152, q: 0, q_max: 18, out: 130, q: 0, q_max: 18
```

### FRR — interfaces

```console
# podman exec frr vtysh -c "show interface brief"
Interface       Status  VRF             Addresses
---------       ------  ---             ---------
main            up      default
underlay0       up      default         10.0.0.3/32
                                        192.168.136.22/25
                                        + fe80::a072:d3ff:fe2e:80e1/64
underlay0.42    up      default
vni210          up      default

Interface       Status  VRF             Addresses
---------       ------  ---             ---------
br-pe-210       up      red             192.168.110.1/24
                                        + fe80::4036:62ff:fe38:f4f1/64
red             up      red
```
