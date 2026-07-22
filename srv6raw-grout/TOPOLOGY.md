# OpenPERouter Network Topology — ISIS + SRv6

## Overview

An ISIS + SRv6 fabric running on top of an OpenShift cluster (3 masters + N workers),
with a TOR router peering externally.

- **Underlay**: ISIS Level-1, single area `49.0001`
- **L3VPN** (north-south): BGP IPv4/IPv6 VPN with SRv6 encapsulation between all nodes and the TOR
- **L2VPN** (east-west): BGP EVPN with VXLAN (VNI 210) between all cluster nodes, reflected by master-0
- **AS**: 65500 (all iBGP)

```
                       ┌──────────────────────────────┐
                       │        TOR / RemotePE        │
                       │   Router ID: 10.0.0.20       │
                       │   Loopback:  fc00:0:20::1    │
                       │   SRv6 pfx:  fd00:20::/48    │
                       │   VRF red:                   │
                       │     lored:    10.10.20.1/32   │
                       │     lo-extra: 10.100.0.1/32   │
                       │       (DNS + NTP server)      │
                       └──────────┬───────────────────┘
                                  │ ISIS L1
                 ┌────────────────┼────────────────┐
                 │                │                │
     ┌───────────┴──┐   ┌────────┴─────┐   ┌─────┴────────┐
     │  master-0    │   │  master-1    │   │  master-2    │
     │  EVPN RR     │   │  EVPN Client │   │  EVPN Client │
     │  10.0.0.2    │   │  10.0.0.3    │   │  10.0.0.4    │
     │  fc00:0:2::1 │   │  fc00:0:3::1 │   │  fc00:0:4::1 │
     │  fd00:2::/48 │   │  fd00:3::/48 │   │  fd00:4::/48 │
     │              │   │              │   │              │
     │  br0: .110.2 │   │  br0: .110.3 │   │  br0: .110.4 │
     │  VRF red:    │   │  VRF red:    │   │  VRF red:    │
     │   br-pe-210  │   │   br-pe-210  │   │   br-pe-210  │
     │   .110.1/24  │   │   .110.1/24  │   │   .110.1/24  │
     │   VNI 210    │   │   VNI 210    │   │   VNI 210    │
     └──────────────┘   └──────────────┘   └──────────────┘
           ▲                   ▲                   ▲
           └───── EVPN RR ─────┴───── EVPN RR ─────┘
                (l2vpn evpn reflected by master-0)

     ┌──────────────┐   ┌──────────────┐
     │  worker-0    │   │  worker-1    │   ...
     │  EVPN Client │   │  EVPN Client │
     │  10.0.0.5    │   │  10.0.0.6    │
     │  fc00:0:5::1 │   │  fc00:0:6::1 │
     │  fd00:5::/48 │   │  fd00:6::/48 │
     │              │   │              │
     │  br0: .110.5 │   │  br0: .110.6 │
     │  VRF red:    │   │  VRF red:    │
     │   br-pe-210  │   │   br-pe-210  │
     │   .110.1/24  │   │   .110.1/24  │
     │   VNI 210    │   │   VNI 210    │
     └──────────────┘   └──────────────┘
           ▲                   ▲
           └───── EVPN RR ─────┘
          (peers with master-0)
```

## Addressing Scheme

All addresses are derived from the node's last octet of `br0` IPv4 (`LAST_OCTET`).

| Node | Router ID | Loopback IPv6 | SRv6 Source | SRv6 Prefix | Underlay IPv6 | Bridge IPv4 | Bridge IPv6 |
|---|---|---|---|---|---|---|---|
| TOR | 10.0.0.20 | fc00:0:20::1 | fd00:20::1 | fd00:20::/48 | fc00:100::20 | — | — |
| master-0 (RR) | 10.0.0.2 | fc00:0:2::1 | fd00:2::1 | fd00:2::/48 | fc00:100::2 | 192.168.110.2 | fd00:110::2 |
| master-1 (client) | 10.0.0.3 | fc00:0:3::1 | fd00:3::1 | fd00:3::/48 | fc00:100::3 | 192.168.110.3 | fd00:110::3 |
| master-2 (client) | 10.0.0.4 | fc00:0:4::1 | fd00:4::1 | fd00:4::/48 | fc00:100::4 | 192.168.110.4 | fd00:110::4 |
| worker-0 (client) | 10.0.0.5 | fc00:0:5::1 | fd00:5::1 | fd00:5::/48 | fc00:100::5 | 192.168.110.5 | fd00:110::5 |
| worker-1 (client) | 10.0.0.6 | fc00:0:6::1 | fd00:6::1 | fd00:6::/48 | fc00:100::6 | 192.168.110.6 | fd00:110::6 |

Workers follow the same addressing formula as masters, continuing from LAST_OCTET 5 onward.

### Address derivation formula

Given `LAST_OCTET` (e.g. `2`, `3`, `4`, `5`, `6`, `20`):

| Address | Formula |
|---|---|
| Router ID / VTEP IP | `10.0.0.{LAST_OCTET}` |
| Loopback IPv6 | `fc00:0:{LAST_OCTET}::1` |
| SRv6 source | `fd00:{LAST_OCTET}::1` |
| SRv6 prefix | `fd00:{LAST_OCTET}::/48` |
| Underlay IPv6 | `fc00:100::{LAST_OCTET}` |
| ISIS NET | `49.0001.0000.0000.{LAST_OCTET:04d}.00` |

## BGP Peering (AS 65500, all iBGP)

### L3VPN sessions (ipv4 vpn + ipv6 vpn)

The TOR peers with all cluster nodes (masters and workers) for north-south L3VPN over SRv6.

| From | To | Peer Group | AFIs |
|---|---|---|---|
| TOR | master-0 (fc00:0:2::1) | PE-NODES | ipv4 vpn, ipv6 vpn |
| TOR | master-1 (fc00:0:3::1) | PE-NODES | ipv4 vpn, ipv6 vpn |
| TOR | master-2 (fc00:0:4::1) | PE-NODES | ipv4 vpn, ipv6 vpn |
| TOR | worker-0 (fc00:0:5::1) | PE-NODES | ipv4 vpn, ipv6 vpn |
| TOR | worker-1 (fc00:0:6::1) | PE-NODES | ipv4 vpn, ipv6 vpn |

### EVPN sessions (l2vpn evpn)

master-0 is the EVPN route reflector. All other nodes (masters and workers) peer only with master-0.
The TOR does not participate in EVPN — north-south traffic uses L3VPN only.

| From | To | Peer Group | Role |
|---|---|---|---|
| master-0 (RR) | master-1 (fc00:0:3::1) | EVPN-CLIENTS | route-reflector-client |
| master-0 (RR) | master-2 (fc00:0:4::1) | EVPN-CLIENTS | route-reflector-client |
| master-0 (RR) | worker-0 (fc00:0:5::1) | EVPN-CLIENTS | route-reflector-client |
| master-0 (RR) | worker-1 (fc00:0:6::1) | EVPN-CLIENTS | route-reflector-client |
| master-1 | master-0 (fc00:0:2::1) | EVPN-RR | client |
| master-2 | master-0 (fc00:0:2::1) | EVPN-RR | client |
| worker-0 | master-0 (fc00:0:2::1) | EVPN-RR | client |
| worker-1 | master-0 (fc00:0:2::1) | EVPN-RR | client |

## SRv6 SIDs

Locator block: `/48`, node: `16 bits`, function: `16 bits` (uSID).

| Node | uN (node SID) | uDT46 (VRF decap) |
|---|---|---|
| TOR | fd00:20:: | fd00:20:0:1:: |
| master-0 | fd00:2:: | fd00:2:0:1:: |
| master-1 | fd00:3:: | fd00:3:0:1:: |
| master-2 | fd00:4:: | fd00:4:0:1:: |
| worker-0 | fd00:5:: | fd00:5:0:1:: |
| worker-1 | fd00:6:: | fd00:6:0:1:: |

## L3VPN Routes (VRF red)

### What each cluster node sees

| Prefix | Next Hop | SRv6 SID | Source |
|---|---|---|---|
| 10.10.20.1/32 | 10.0.0.20 | fd00:20:0:1:: | TOR VRF loopback (lored) |
| 10.100.0.1/32 | 10.0.0.20 | fd00:20:0:1:: | TOR DNS/NTP loopback (lo-extra) |
| 192.168.110.0/24 | connected | — | Local br-pe-210 (L2 gateway) |

### What the TOR sees

| Prefix | Next Hop | SRv6 SID | Source |
|---|---|---|---|
| 192.168.110.2/32 | 10.0.0.2 | fd00:2:0:1:: | master-0 bridge IP |
| 192.168.110.3/32 | 10.0.0.3 | fd00:3:0:1:: | master-1 bridge IP |
| 192.168.110.4/32 | 10.0.0.4 | fd00:4:0:1:: | master-2 bridge IP |
| 192.168.110.5/32 | 10.0.0.5 | fd00:5:0:1:: | worker-0 bridge IP |
| 192.168.110.6/32 | 10.0.0.6 | fd00:6:0:1:: | worker-1 bridge IP |
| 10.10.20.1/32 | connected | — | Local lored |
| 10.100.0.1/32 | connected | — | Local lo-extra |

## L2VPN / EVPN (VNI 210)

All cluster nodes (masters and workers) share an L2 segment via VXLAN bridge `br-pe-210`:
- Gateway IP: `192.168.110.1/24` + `fd00:110::1/64` (anycast on all nodes)
- VNI: 210
- RT: 65500:210

EVPN type-2 (MAC/IP) and type-3 (BUM/VTEP) routes are exchanged between
all cluster nodes via master-0 as route reflector. The TOR does **not** participate
in EVPN L2 — north-south traffic only via L3VPN.

## Services on TOR (VRF red)

### DNS (dnsmasq on 10.100.0.1)

| Record | Target |
|---|---|
| api.sno-lab.example.com | 192.168.110.10 (API VIP) |
| api-int.sno-lab.example.com | 192.168.110.10 (API VIP) |
| *.apps.sno-lab.example.com | 192.168.110.11 (Ingress VIP) |

### NTP (chronyd on 10.100.0.1)

Stratum 3 orphan server. All cluster nodes sync to it via the SRv6 L3VPN path.

## ISIS Underlay

- Area: `49.0001`
- Level: L1 only
- Interface: `enp2s0` on cluster nodes, dedicated interface on TOR
- All nodes form L1 adjacencies on the shared broadcast segment
