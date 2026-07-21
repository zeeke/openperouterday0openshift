# OpenPERouter — Rawconfig Deployment

A rawconfig deployment of OpenPERouter on an OpenShift cluster. No controller
manages FRR — systemd services derive addressing at boot, render FRR config
from templates, and build the VRF/VXLAN/bridge infrastructure.

## Architecture

```
              ┌─────────┐
              │   TOR   │
              └────┬────┘
                   │  ISIS + SRv6 (L3VPN)
        ┌──────────┼──────────┐
        │          │          │
   ┌────┴───┐ ┌───┴────┐ ┌───┴────┐
   │master-0│ │master-1│ │worker-0│  ...
   │  (RR)  │ │        │ │        │
   └────────┘ └────────┘ └────────┘
        ◄── EVPN / VXLAN (L2VPN) ──►
            reflected by master-0
```

- **North-south** (nodes ↔ TOR): L3VPN over SRv6 (ISIS underlay)
- **East-west** (node ↔ node): EVPN with VXLAN, master-0 as route reflector
- The TOR does **not** participate in EVPN

See [TOPOLOGY.md](TOPOLOGY.md) for full addressing and peering details.

## Host Configuration

The systemd services in [`extras/rawconfig/`](extras/rawconfig/) run in
sequence at boot to configure each node:

| Script | What it does |
|--------|-------------|
| `setup-underlay.sh` | Derives all addressing from the br0 IP, moves the underlay NIC into the FRR namespace, configures loopbacks and SRv6 sysctls |
| `setup-network.sh` | Creates VRF, VXLAN tunnel (VNI), EVPN bridge, and veth pair connecting br-ex to the FRR namespace |
| `generate-config.sh` | Picks the RR or client template based on node index, renders it with `envsubst` |
| `bridge-refresher.sh` | Continuously pings VIPs on the EVPN bridge so ARP entries stay alive and EVPN type-2 routes are advertised |
| `openperouter-common.sh` | Shared helpers (logging, namespace utilities) sourced by all scripts |

## FRR Configuration

FRR config is rendered from two templates in `extras/rawconfig/`:

- **`openpe_evpn.yaml_rr.template`** — route reflector (master-0): peers with
  the TOR for L3VPN and reflects EVPN to all other nodes
- **`openpe_evpn.yaml.template`** — client (all other nodes): peers with the
  TOR for L3VPN and with the RR for EVPN

`generate-config.sh` selects the template by comparing the node's last octet
against `RR_NODE_IDX`, substitutes variables, and writes the result for the
FRR reloader to apply.

## Configuration (vpn-setup.env)

All tunable parameters live in [`extras/rawconfig/vpn-setup.env`](extras/rawconfig/vpn-setup.env):

| Variable | Default | Description |
|----------|---------|-------------|
| `UNDERLAY_NIC` | `enp2s0` | Physical NIC moved into the FRR namespace for ISIS |
| `FRR_READY_TIMEOUT` | `60` | Seconds to wait for the FRR container to start |
| `BR0_READY_TIMEOUT` | `120` | Seconds to wait for br0/br-ex to get an IP |
| `BGP_AS` | `65500` | iBGP AS number (shared by all nodes) |
| `RR_NODE_IDX` | `2` | Node index of the EVPN route reflector |
| `TOR_LOOPBACK` | `fc00:0:20::1` | TOR IPv6 loopback — all nodes peer with this for L3VPN |
| `EVPN_LISTEN_RANGE` | `fc00::/16` | BGP listen range for dynamic EVPN peers on the RR |
| `ISIS_AREA` | `49.0001` | ISIS area prefix (nodes derive their NET from this) |
| `VRF_NAME` | `red` | VRF name |
| `VRF_TABLE` | `1100` | VRF routing table ID |
| `L2_VNI` | `210` | VXLAN VNI for the L2 EVPN overlay |
| `VXLAN_PORT` | `4789` | VXLAN UDP port |
| `L2_GATEWAY_IP` | `192.168.110.1/24` | Anycast gateway IPv4 on the EVPN bridge |
| `L2_GATEWAY_IP_V6` | `fd00:110::1/64` | Anycast gateway IPv6 on the EVPN bridge |

## Building

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file>`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`
