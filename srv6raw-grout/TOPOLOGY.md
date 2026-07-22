# OpenPERouter Network Topology — ISIS + SRv6

## Overview

An ISIS + SRv6 fabric running on top of an OpenShift cluster (3 masters + N
workers), with an external SRv6 gateway (bastion) providing north-south
connectivity, DNS, NTP and internet access via NAT.

- **Underlay**: ISIS Level-1, single area `49.0001`, point-to-point
- **L3VPN** (north-south): BGP IPv4/IPv6 VPN with SRv6 encapsulation (uSID, H.Encaps.Red)
- **L2VPN** (east-west): BGP EVPN with VXLAN (VNI 210) between all cluster nodes
- **Dataplane**: grout (DPDK), two SR-IOV VFs per PF bound for underlay
- **AS**: 65500 (all iBGP)

```
                       ┌───────────────────────────────┐
                       │    SRv6 Gateway               │
                       │   Router ID: 10.0.0.20        │
                       │   Loopback:  fc00:0:14::1     │
                       │   SRv6 pfx:  fd00:14::/48     │
                       └──────────┬────────────────────┘
                                  │ ISIS L1 p2p
                 ┌────────────────┼────────────────┬──────────┐
                 │                │                │          │
     ┌───────────┴──┐   ┌─────────┴────┐   ┌───────┴──────┐   │
     │  master-0    │   │  master-1    │   │  master-2    │   │
     │  EVPN RR     │   │  EVPN client │   │  EVPN client │   │
     │  10.0.0.2    │   │  10.0.0.3    │   │  10.0.0.4    │   │
     │  fc00:0:2::1 │   │  fc00:0:3::1 │   │  fc00:0:4::1 │   │
     │  fd00:2::/48 │   │  fd00:3::/48 │   │  fd00:4::/48 │   │
     │  2x CX6 PFs  │   │  2x CX6 PFs  │   │  2x E810 PFs │   │
     │              │   │              │   │              │   │
     │  host .110.2 │   │  host .110.3 │   │  host .110.4 │   │
     │  VRF red:    │   │  VRF red:    │   │  VRF red:    │   │
     │   br-pe-210  │   │   br-pe-210  │   │   br-pe-210  │   │
     │   VNI 210    │   │   VNI 210    │   │   VNI 210    │   │
     └──────────────┘   └──────────────┘   └──────────────┘   │
           ▲                   ▲                   ▲          │
           └───── EVPN RR ─────┴───── EVPN RR ─────┘          │
                (l2vpn evpn reflected by master-0)            │
                                                              │
     ┌──────────────┐                                         │
     │ worker-0     │                                         │
     │ EVPN Client  │─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ───┘
     │ 10.0.0.5     │
     │ fc00:0:5::1  │
     │ fd00:5::/48  │
     │ 2x ??? PFs   │      ....
     │              │
     │ host: .110.5 │
     │  VRF red:    │
     │   br-pe-210  │
     │   VNI 210    │
     └──────────────┘
           ▲
           └───── EVPN RR ─ ─ ─ ─
          (peers with master-0)
```

## SR-IOV VF Layout

Each node has two PFs (physical functions). Both are configured with 16 VFs.

| VF     | Role       | Details                                          |
|--------|------------|--------------------------------------------------|
| VF0    | underlay   | bound to grout (mlx5: netns move, ice: vfio-pci) |
| VF1    | host       | hardware VLAN 42, cluster IP, default route      |
| VF2-15 | workload   | available for pod SR-IOV requests                |

PF0 VF0 becomes grout port `underlay0`, PF1 VF0 becomes `underlay1`.
PF MTU is set to 1800 in agent-config.yaml (VXLAN overhead over 1500).

VF binding is triggered automatically by the NM dispatcher script
`99-perouter`: on VF0 activation it calls `perouter-bind.sh`, on the
VF carrying the default route it calls `perouter-host-dispatch.sh`.

## Addressing Scheme

All per-node addresses are derived at boot from the host VF's last IPv4
octet (`LAST_OCTET`) using printf format strings defined in
`openperouter.env`. IPv6 groups use `%x` (hex), IPv4 octets use `%d`.

### Format strings (from openperouter.env)

| Variable        | Pattern                       | Example (node 2)          | Example (node 20)         |
|-----------------|-------------------------------|---------------------------|---------------------------|
| ROUTER_ID_FMT   | `10.0.0.%d`                   | 10.0.0.2                  | 10.0.0.20                 |
| LOOPBACK_V6_FMT | `fc00:0:%x::1`                | fc00:0:2::1               | fc00:0:14::1              |
| SRV6_SOURCE_FMT | `fd00:%x::1`                  | fd00:2::1                 | fd00:14::1                |
| SRV6_PREFIX_FMT | `fd00:%x`                     | fd00:2                    | fd00:14                   |
| UNDERLAY_V6_FMT | `fc00:100::%x`                | fc00:100::2               | fc00:100::14              |
| ISIS_NET        | `49.0001.0000.0000.{%04d}.00` | 49.0001.0000.0000.0002.00 | 49.0001.0000.0000.0020.00 |

### Current nodes

| Node          | LAST_OCTET | Router ID | Loopback IPv6 | SRv6 Source | SRv6 Prefix  | Host IP       |
|---------------|------------|-----------|---------------|-------------|--------------|---------------|
| gateway       | 20         | 10.0.0.20 | fc00:0:14::1  | fd00:14::1  | fd00:14::/48 | —             |
| master-0 (RR) | 2          | 10.0.0.2  | fc00:0:2::1   | fd00:2::1   | fd00:2::/48  | 192.168.110.2 |
| master-1      | 3          | 10.0.0.3  | fc00:0:3::1   | fd00:3::1   | fd00:3::/48  | 192.168.110.3 |
| master-2      | 4          | 10.0.0.4  | fc00:0:4::1   | fd00:4::1   | fd00:4::/48  | 192.168.110.4 |

## BGP Peering (AS 65500, all iBGP)

### L3VPN sessions (ipv4 vpn + ipv6 vpn)

The SRv6 gateway peers with all cluster nodes for north-south traffic.
The gateway uses `bgp listen range fc00::/16` for dynamic peering so
new nodes are accepted automatically.

### EVPN sessions (l2vpn evpn)

master-0 (`RR_NODE_IDX=2`) is the EVPN route reflector. All other nodes
peer with master-0 only. The RR also uses `bgp listen range fc00::/16`
for dynamic client acceptance. The gateway does not participate in EVPN.

## SRv6 SIDs

Locator block: `/48`, node: `16 bits`, function: `16 bits` (uSID).

| Node      | uN (node SID) | uDT46 (VRF decap) |
|-----------|---------------|-------------------|
| gateway   | fd00:14::     | fd00:14:0:1::     |
| master-0  | fd00:2::      | fd00:2:0:1::      |
| master-1  | fd00:3::      | fd00:3:0:1::      |
| master-2  | fd00:4::      | fd00:4:0:1::      |

## L2VPN / EVPN (VNI 210)

All cluster nodes share an L2 segment via VXLAN bridge `br-pe-210`:
- Anycast gateway: `192.168.110.1/24` + `fd00:110::1/64` (same on all nodes)
- VNI: 210
- RT: 65500:210

EVPN type-2 (MAC/IP) and type-3 (BUM/VTEP) routes are reflected by
master-0. The gateway does not participate in EVPN L2.

## SRv6 Gateway (Bastion) Architecture

The gateway runs FRR in a `perouter` network namespace with the private
NIC (ISIS underlay). A VRF `red` inside that netns handles L3VPN traffic.
A veth pair bridges VRF red to the default netns where DNS, NTP and NAT
live. This avoids cross-VRF NAT issues (conntrack cannot track cross-VRF
connections in Linux).

```
perouter netns                         default netns
┌─────────────────────────┐            ┌──────────────────────┐
│  eno12399np0 (ISIS)     │            │  lo: 10.100.0.1 (DNS)│
│  VRF red                │            │      10.10.20.1      │
│    veth-frr 10.200.0.1 ─┼── veth ──▶ │  veth-host 10.200.0.2│
│  FRR container          │            │  eno8303 → NAT       │
└─────────────────────────┘            └──────────────────────┘
```

## ISIS Underlay

- Area: `49.0001`
- Level: L1 only
- All interfaces: point-to-point
- Addresses are configured directly on the ISIS interface (FRR
  unnumbered is broken: https://github.com/FRRouting/frr/issues/16018)

## Configuration Files

Only two files need per-deployment tuning:

- **`openperouter.env`** — fabric-wide settings: AS number, format
  strings, VNI, gateway address, RR node index. Shared by all nodes.
- **`agent-config.yaml`** — per-node hardware: PF names, MAC addresses,
  host IPs, VF layout, DNS/NTP sources.

Everything else (FRR config, grout ports, addresses) is derived at boot.

## Adding Worker Nodes

Workers participate in the same ISIS + SRv6 + EVPN fabric as masters.
They use the same scripts, quadlets and openperouter.env. The only file
that needs editing is `agent-config.yaml`.

### Steps

1. Pick a `LAST_OCTET` for the new worker. It must be unique across all
   nodes and the gateway. In this deployment, masters use 2/3/4 and the
   gateway uses 20, so workers can start at 5.

2. Add a host entry in `agent-config.yaml`. The structure is identical
   to a master entry — only the hostname, MAC address, PF/VF kernel
   names, and host IP change. For example, a worker with a ConnectX-6:

   ```yaml
   - hostname: worker-0
     rootDeviceHints:
       deviceName: /dev/sda
     interfaces:
     - name: ens1f0np0
       macAddress: aa:bb:cc:dd:ee:ff
     networkConfig:
       interfaces:
       - name: ens1f0np0
         type: ethernet
         state: up
         mtu: 1800
         ipv4:
           enabled: false
         ipv6:
           enabled: false
         ethernet:
           sr-iov:
             total-vfs: 16
             vfs:
             - id: 0
               vlan-id: 0
               spoof-check: false
               trust: true
             - id: 1
               vlan-id: 42
               spoof-check: false
               trust: true
       - name: ens1f1np1
         type: ethernet
         state: up
         mtu: 1800
         ipv4:
           enabled: false
         ipv6:
           enabled: false
         ethernet:
           sr-iov:
             total-vfs: 16
             vfs:
             - id: 0
               vlan-id: 0
               spoof-check: false
               trust: true
       - name: ens1f0v0
         type: ethernet
         state: up
       - name: ens1f1v0
         type: ethernet
         state: up
       - name: ens1f0v1
         type: ethernet
         state: up
         ipv4:
           enabled: true
           auto-dns: false
           address:
           - ip: 192.168.110.5
             prefix-length: 24
           dhcp: false
         ipv6:
           enabled: true
           auto-dns: false
           autoconf: false
           address:
           - ip: fd00:110::5
             prefix-length: 64
           dhcp: false
       dns-resolver:
         config:
           server:
           - 10.100.0.1
           - fd00:100::1
       routes:
         config:
         - destination: 0.0.0.0/0
           next-hop-address: 192.168.110.1
           next-hop-interface: ens1f0v1
         - destination: ::/0
           next-hop-address: fd00:110::1
           next-hop-interface: ens1f0v1
   ```

3. Regenerate the config image. No changes to openperouter.env, butane,
   scripts, or FRR templates are needed. The worker boots, the NM
   dispatcher derives all addresses from the host IP (last octet 5),
   and the node joins the fabric automatically:

   - ISIS adjacency forms on underlay0/underlay1
   - BGP L3VPN session establishes with the gateway (dynamic peering via
     `bgp listen range`)
   - EVPN session establishes with master-0 (dynamic peering via `bgp
     listen range` on the RR)
   - VXLAN bridge `br-pe-210` joins the L2 overlay

### What makes this work without extra configuration

- **Dynamic BGP peering**: both the SRv6 gateway and the EVPN RR
  (master-0) use `bgp listen range fc00::/16`. Any node whose loopback
  falls in that range is accepted as a peer automatically.
- **Address derivation**: all per-node addresses (router ID, loopback,
  SRv6 locator, ISIS NET) are computed from `LAST_OCTET` by the NM
  dispatcher at boot. No hardcoded addresses in scripts or templates.
- **FRR template selection**: `generate-config.sh` checks whether
  `LAST_OCTET == RR_NODE_IDX`. Workers always get the client template
  since their last octet is never 2.
- **EVPN RR client template**: the client template points at
  `RR_LOOPBACK` (derived from `LOOPBACK_V6_FMT` and `RR_NODE_IDX`),
  so it works for any node without modification.

### NIC naming differences

VF kernel names depend on the PF driver. The only thing that varies
per-node in agent-config.yaml is the interface naming:

| NIC family        | PF names              | VF0 names               | VF1 (host) |
|-------------------|-----------------------|-------------------------|------------|
| ConnectX-6 (mlx5) | ens1f0np0 / ens1f1np1 | ens1f0v0 / ens1f1v0     | ens1f0v1   |
| E810 (ice)        | eno12399 / eno12409   | eno12399v0 / eno12409v0 | eno12399v1 |

The dispatcher and bind scripts work with any naming — they look up VF
index via sysfs, not by parsing interface names.
